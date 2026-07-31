# Synthesis — Standard/Analytical Plan Reviews, C11-184

**Plan:** `.lattice/plans/task_01KYMTXQVWCXCF0TGN5ZWG341E.md` (Flagged and suppressed agents)
**Reviews synthesized:** `standard-claude.md`, `standard-codex.md`, `standard-gemini.md`
**Reviewed:** 2026-07-28 17:26
**Synthesis written:** 2026-07-28

---

## Executive Summary

1. **All three models endorse the architecture.** There is no dissent on the core shape: two orthogonal persisted modifiers over an unchanged four-case lifecycle; canonical metadata as the persistence substrate; one serialized `SurfaceAttentionService` commit boundary; raw-vs-signal separation inside `TerminalNotificationStore`; a generic (non-c11-aware) Bonsplit presentation seam; the flag banner mounted in the AppKit portal layer rather than SwiftUI layout flow. No reviewer proposes a redesign. Whatever else happens, **do not re-plan.**

2. **The verdict splits 2–1 toward "Needs revision."** Claude and Codex both land on *Needs revision, not rethinking* — revisions measured in hours of contract-tightening, not weeks. Gemini alone says *Ready to execute*, treating the same gaps as implementation-time details.

3. **The verdict split correlates with review depth, and that is itself the strongest meta-signal in the pack.** Claude verified roughly a dozen structural claims against the tree and cites specific files. Codex cites exact line ranges (`SurfaceMetadataStore.swift:725-742`) for a blocking finding. Gemini cites no code at all and its review is roughly one-fifth the length of the other two. The "Ready" verdict is the one produced without reading the implementation surface. **Weight it accordingly: treat the pack as 2-of-2-who-checked saying "not yet."**

4. **Three findings are independently blocking and were each found by only one model** — which means the union, not the intersection, is the actionable list:
   - Claude: `Workspace.syncSurfaceTabActivityStateForPanel`'s early return will silently swallow the plan's own headline scenario (flag raised mid-working never turns the tab violet).
   - Codex: the flag epoch has **no durable representation** under the current `setMetadataLocked` write behavior — a revised reason writes a new timestamp, so the epoch is lost on relaunch.
   - Codex: the signal-index refresh has **no publication mechanism** — rebuilding a private index does not invalidate views observing `@Published notifications`.

5. **Two reviewers independently reached the same conclusion on the held Phase 3 decision (suppressed + flagged direct delivery), but disagree on its severity.** Claude treats the held decision as *correctly isolated* — a strength — that merely needs resolving before Phase 3. Codex treats it as *actively blocking* because the plan's validation matrix and acceptance checklist already pre-accept "delivery pierces suppression" while the binding spec says the opposite and the plan's own held-decision section says "no." Codex is right that the plan currently has two contradictory acceptance outcomes; Claude is right that the *architecture* isolates it cleanly. Both are true: the design is parameterized, the acceptance criteria are not.

6. **The sharpest live disagreement is PR packaging.** Claude argues forcefully for three PRs along the plan's own commit-unit boundaries; Codex explicitly considered the split and defends the single PR; Gemini is silent. This is a genuine judgment fork, not an oversight, and needs an operator call.

7. **The second sharpest disagreement is the latency gate.** Claude searched the repo, found no keystroke-to-paint harness, and calls the ≤1 ms p95 hard gate a questionable bet with an unscoped instrument hidden inside a validation step. Gemini names the same gate a **key strength** ("mature engineering"). Only Claude checked whether the instrument exists.

8. **Consolidated position:** the plan is architecturally ready and contractually unready. Roughly 10 contract amendments (below) plus one packaging decision convert it to executable. None require revisiting the model.

---

## 1. Where the Models Agree (Highest Confidence)

### 1.1 Agreement on strengths — unanimous, 3/3

1. **Orthogonal modifiers over an unchanged lifecycle is the correct domain model.** All three explicitly reject the linear `suppressed | normal | flagged` alternative and the "add lifecycle cases" alternative, for the same reason: neither can express the headline case (suppressed *and* flagged).
2. **Canonical metadata as substrate is correct.** Free persistence, free snapshot/restore, free `get-metadata` introspection, no second store. Codex and Claude both note the cost (a `set_metadata` bypass vector) is the direct consequence and must be closed.
3. **The serialized `SurfaceAttentionService` commit boundary is the right center of gravity.** All three name cross-layer drift as the failure mode it prevents; Claude calls closing the bypass in the plan rather than in review "the single strongest decision in the document."
4. **Raw history vs. signal eligibility is the right abstraction.** Suppression as filtering, not deletion or read-state mutation. Unanimous.
5. **Flags must not write `TerminalNotificationStore`.** All three endorse direct delivery and the double-count argument; Gemini explicitly weighs and rejects the "write it but tag it" alternative.
6. **The portal-hosted banner is correct and load-bearing.** All three independently articulate *why*: a layout-flow banner resizes the PTY and garbles active TUI rendering mid-run.
7. **The Bonsplit seam is correctly generic.** Extending the host-presentation seam (alternate core color, `breathe` sampler, split base/explicit motion permission) rather than teaching Bonsplit about "flags" is endorsed by all three as correct submodule hygiene. Claude adds that it is a genuinely small delta because C11-183 already shipped `steppedFill / easedDip / binaryFlash` and the shared clock.
8. **Renderers consume precomputed immutable values; no metadata queries in typing-hot rows.** Unanimous, and all three tie it to c11's documented typing-latency constraints.

### 1.2 Agreement on gaps — 2/3 or 3/3

9. **Launch-time `--flag` will fire a system notification at the operator who just typed the command.** (Claude G2; Codex Q2/Q3.) Both call it unspecified and both note the spec's model of a launch flag is a *watch marker*, not an interrupt. Claude proposes the concrete rule: `by: .operator` raises do not deliver, kept independent of the held suppression branch. Codex adds a follow-on nobody else asked: does a launch-time mission flag stay raised through ordinary completion?
10. **Direct system-notification lifecycle is under-specified.** (Codex #5; Gemini #3/Q2.) No stable OS notification identifier, no revision-replacement semantics, no statement on whether `lower()` revokes pending/delivered notifications via `removeDeliveredNotifications`. Codex additionally notes `UNUserNotificationCenter.add` is **asynchronous**, so "delivery completes before the socket response" can only mean *scheduling was enqueued*, not that macOS delivered the banner — the plan's wording overpromises.
11. **The "Jump to Latest Unread" affordances go stale.** (Claude G4; Codex #6.) Same finding from two angles: Claude counts 14 call sites and three user-facing localized labels and warns the six-locale re-translation forces the decision into Phase 1; Codex adds the *enablement* half — the status-menu item is enabled off unread count, so with one flag and zero signal-eligible unread the new action exists while the menu item is disabled and mislabeled.
12. **`flag.list` scope is unstated.** (Claude G5; Codex non-blocking list.) Process-global across windows, scoped to the addressed window, or filterable? Claude argues it should be app-global with workspace refs per entry, matching the notification store's inherited scope.
13. **The 256-character reason cap needs sharper semantics.** (Claude G10; Codex final bullet.) Claude: rejection is the wrong failure mode for an agent that is *already blocked* — consider truncate-with-warning, and at minimum put the cap in the error message. Codex: specify grapheme clusters vs. scalars, measure after trimming/normalization, and reject *all* Unicode newline separators, not only LF. These compose into one amendment.
14. **The plan is unusually well grounded in the repo.** Claude and Codex both credit it for repository-specific hazard awareness (typing-hot paths, Reduce Motion authority, C11-165 focus/ref behavior, submodule reachability, CI-only test execution per the operator's constraint). Claude's phrasing: "The author read the code, not just the spec."

---

## 2. Where the Models Diverge (The Disagreement Is Signal)

### 2.1 Readiness verdict — 2–1

| Model | Verdict | Basis |
|---|---|---|
| Claude | Needs revision (hours, not a rethink) | 6 blocking items, 4 strongly-recommended |
| Codex | Needs revision (contract amendments, not redesign) | 7 blocking contract gaps |
| Gemini | **Ready to execute** | "Minor gaps can be handled during implementation" |

**Reading:** Gemini's own three named gaps (revision spam, z-order fragility, notification lifecycle) are non-trivial, yet it classifies them as implementation-time. Given Gemini did no code verification, its "Ready" reflects an assessment of the plan *as a document* rather than of the plan *against the tree*. The two reviews that opened source files both concluded the contracts are underspecified in ways that would produce internally inconsistent behavior. **Go with Needs revision.**

### 2.2 PR packaging — direct, considered disagreement

- **Claude: split into three PRs.** Argues the plan's own commit-unit list (`model/tests; primitives/launch; signal/navigation; renderer/submodule; banner/UI; localization/skill`) *is already* the split: PR1 = Phases 0–2 (headless, logic-testable, zero rendering risk, ships real value); PR2 = Phase 3 (highest correctness risk — raw/signal drift, double-count, edge emission — worth reviewing against a stable base); PR3 = Phases 4–6 (all validation risk, tagged build, 20-agent harness, computer-use approval). Key argument: a failed latency gate in PR3 otherwise holds the model, primitives, and events hostage; and the reviewer's bounded budget (one correctness review, one fix pass, one terminal re-review) is appropriate for a normal PR, not for 22 files of cross-cutting change in one sitting. Claude also ties this to the CI-only test loop: "a 6-file PR with a CI-only test loop is workable; a 22-file one is a grind."
- **Codex: one PR is defensible.** Explicitly weighed the split and rejected it — a model/signal PR without a UI PR "creates an awkward intermediate state where canonical modifiers exist without a trustworthy operator surface." Concedes the Bonsplit commit must still be independently reviewable and pushed/reachable before the parent pointer lands.
- **Gemini:** does not address packaging.

**Reading:** Both arguments are sound and they optimize different things — Claude optimizes reviewability and revert granularity under a slow CI-only inner loop; Codex optimizes user-facing coherence of each landed state. Note that Claude's "PR1 ships real value" claim (agents can flag, Overwatch consumes events, `get-metadata` round-trips) partially answers Codex's objection: the intermediate state has an *agent-facing* surface even without the operator-facing one. **This is an operator call, not a resolvable technical dispute.** If the latency gate stays a hard blocker, Claude's isolation argument gets materially stronger.

### 2.3 The held Phase 3 decision (suppressed + flagged direct delivery) — three different readings

- **Claude:** a **strength**. "Exactly one policy branch at the direct flag delivery call site," with an explicit list of what may *not* depend on it, "turns an open question from a blocker into a parameter. This is the right way to carry an unresolved decision through a plan." Requires resolution before Phase 3 starts, but classes it as a one-question conversation.
- **Codex:** **blocking**, and the first item in its executive summary. The plan is not merely holding the decision — it has already **pre-committed to both answers**: tagged validation item 8 and the acceptance checklist require the direct notification to pierce suppression, the binding spec says "Suppressed surfaces deliver no system notification, by definition," and the held-decision section says the faithful spec reading is "no." "The implementation plan as a whole cannot have two acceptance outcomes."
- **Gemini:** treats it as **already resolved** — describes the plan as faithfully implementing "the nuanced rule that a flag overrides suppression," apparently reading the validation matrix as authoritative.

**Reading:** Codex is correct on the facts and Claude is correct on the architecture. The design isolates the decision cleanly; the *acceptance criteria* do not, and Gemini's misreading is direct evidence that a reader will pick up the wrong answer from the document as written. **Resolve the decision and then make the spec, matrix, validation steps, acceptance checklist, and tests all agree — and record which document became authoritative.**

### 2.4 The ≤1 ms p95 latency gate — strength or unscoped liability?

- **Claude:** questionable bet. Searched the repo: **no keystroke-to-paint harness exists** (only prose references in `docs/c11-textbox-port-plan.md` and its review pack). Two objections: (a) building reliable keystroke-to-paint measurement on macOS with a Ghostty-embedded renderer is its own engineering problem, hidden as an unscoped subtask inside a validation step; (b) 1 ms is likely below the noise floor — run-to-run variance across a 20-surface fleet will plausibly exceed the delta being detected. Proposes either scoping the harness as a named deliverable, or restating the gate in measurable proxies: `TabItemView` body-evaluation counts during a typing burst (`BonsplitDebugCounters` already exists), shared-clock subscriber count, sustained-typing CPU — arguing the proxies are the *better* gate because they fail diagnostically ("body churn went up 40×" tells you what to fix; "p95 moved 1.3 ms" does not).
- **Gemini:** names the latency gate and its pre-registered fallback ladder a **key strength** — "mature engineering."
- **Codex:** neutral-positive, folds it into "good operational gates."

**Reading:** These are compatible if you separate the *ladder* from the *trigger*. All three agree the pre-registered fallback ladder (stepped fill off → dip off → static base; flags static violet independently) is good discipline. Claude's point is narrower and unrebutted: the ladder needs a gate it can actually be triggered by, and no instrument exists. **Claude is the only model that checked. Treat the harness as either a named deliverable or replace the threshold with proxies.**

### 2.5 Reason revisions — idempotency strength or notification spam risk?

- **Claude:** a **key strength**, and evidence of adversarial thinking. Praises the precise semantics ("preserves the original timestamp, emits one new `flag.raised` and one policy-governed updated notification, but never creates a second queue entry; only an explicit lower followed by a new raise starts a new epoch") because it defuses the agent that revises its reason every thirty seconds and perpetually resets its own queue age.
- **Gemini:** a **weakness**. The same permission means an agent streaming its thought process into the reason field spams the operator's macOS Notification Center; no debouncing or rate-limiting is mentioned.
- **Codex:** neither — identifies the deeper problem beneath both: the epoch preservation Claude praises **is not representable** under the current write path (see 3.2 below), and the notification-identity semantics Gemini worries about are undefined.

**Reading:** Not actually a contradiction. Claude assessed *queue-order* idempotency (which the plan does specify well); Gemini assessed *OS-notification* idempotency (which the plan does not specify at all); Codex found that the mechanism underpinning Claude's praise doesn't exist yet. All three amendments are needed, and they converge on one fix: **a stable per-surface-per-epoch OS notification identifier so a revision replaces rather than appends, plus a durable epoch primitive.**

### 2.6 Generic metadata writes — closed or still open?

- **Claude:** the plan "closes the bypass explicitly with adversarial coverage," enumerating generic set/clear, replace, clear-all, restore, launch stamping, detach/transfer, close, and prune. Rates it a top-3 strength.
- **Codex:** the plan leaves route-vs-reject as **alternatives**, not a decision, and the two have materially different attribution, timestamp, idempotency, and mixed-transaction semantics. Recommends making the flag-family methods the *sole* mutation API (fields stay visible through `get-metadata`; generic writes touching them fail with a precise protocol error), and enumerates five things the plan must specify if generic writes remain allowed.

**Reading:** Claude read the *enumeration of bypasses* as closure; Codex read the *un-chosen alternative* as an open contract. Codex is right that the plan names the perimeter without picking the door. **Decide it before Phase 0.**

---

## 3. Unique Insights (Single-Model Findings)

Each of these was surfaced by exactly one reviewer. Several are blocking. This section is where the three-model pack earns its cost.

### 3.1 Claude only — the mark-sync early return will break the headline scenario

`Workspace.syncSurfaceTabActivityStateForPanel` guards on:

```swift
guard existing.activityState != activityState
    || existing.showsNotificationBadge != shouldShowLegacyUnread else { return }
```

A flag raised mid-**working** changes neither `activityState` (still `.running`) nor the badge. The guard early-returns, `updateTab` is never called, and **the surface tab never turns violet.** That is the plan's own validation scenario #2 ("a flag raised mid-working: both marks snap violet"), and it fails on first run. Claude's note: this is the kind of defect that is obvious in hindsight and invisible in review. Requires comparing the *full presentation value*, not just `activityState`, plus a named regression test.

### 3.2 Codex only — the flag epoch has no durable representation (BLOCKING)

`SurfaceMetadataStore.setMetadataLocked` preserves the existing `SourceRecord.ts` **only for an identical same-source write** (`Sources/SurfaceMetadataStore.swift:725-742`). A changed reason writes a new value *and a new timestamp*. Therefore:
- using the source timestamp directly moves a revised flag to the back of the queue;
- preserving the epoch only in the observable index loses it on relaunch;
- restoring from snapshot cannot recover an epoch that was already overwritten.

Recommendation: an attention-specific atomic metadata mutation that updates the flag value while explicitly preserving the existing `flag` source-record timestamp when the flag was already active. A canonical `flag_raised_at` key would also work but expands the public model beyond the two binding fields and adds clear/replace surface area. The same primitive must define mixed `mode=replace` and lower-then-raise atomically. **This is the single most consequential finding in the pack** — it silently invalidates a semantic the plan states as settled and that Claude independently praised.

### 3.3 Codex only — the signal index has no publication mechanism (BLOCKING)

`TerminalNotificationStore.notifications` is `@Published`; its `didSet` rebuilds private indexes; views observe the array and call computed methods (`unreadCount`, `hasUnreadNotification`). **If suppression changes while the notification array does not, rebuilding a private signal index will not invalidate those views.** The plan correctly forbids rewriting `notifications` just to trigger `didSet` — but names no replacement. Needs an explicit published signal snapshot or monotonic `signalRevision`, with index replacement and publication inside the attention commit, and no scattered ad-hoc `objectWillChange.send()`.

### 3.4 Codex only — no consumer migration contract for raw vs. signal

Do not silently change the meaning of `hasUnreadNotification`. Introduce `hasRawUnreadNotification` and `hasSignalEligibleUnreadNotification` and migrate each caller deliberately. Codex supplies the classification: raw for the notifications list and explicit mark-read/remove; signal-eligible for sidebar waiting state, workspace pulse demand, surface-tab waiting presentation, titlebar badge, menu-bar icon/count, ⌥V fallback, and waiting edges. Direct raw-array consumers in `ContentView`, `WorkspaceContentView`, `c11App`, `UpdateTitlebarAccessory`, and `AppDelegate` must join the owned-seam audit even if some don't change. Separately: focusing a suppressed surface should still mark its raw record read — that should not silently stop working just because the record contributes no signal.

### 3.5 Codex only — `dominant` cannot return "flagged" (type contract gap)

"Dominant attention precedence is flagged > waiting > working > idle > cold without adding a `WorkspacePulseState` case" is prose, not an executable type contract. `WorkspacePulseSummary.dominant` returns `WorkspacePulseState` today and cannot return "flagged" without one of: a separate `WorkspacePulseDominance`/attention-priority type; a `(state, flagged)` presentation value; or a `dominantAgent` plus derived presentation. `flaggedCount` alone does not define what `dominant` returns for a flagged-working agent.

### 3.6 Codex only — the flag reason cannot reach the required accessibility output

The plan requires accessibility to announce flag state *and reason* in both renderers, but neither payload carries it: `WorkspacePulseAgent` carries booleans with no reason; the proposed generic Bonsplit presentation carries color, motion, and alternate core color but no accessibility override. Carry a normalized reason into the sidebar agent presentation and add a generic host-supplied accessibility descriptor to Bonsplit (the public Bonsplit vocabulary can stay generic — it need not be called `flagReason`).

### 3.7 Codex only — do not encode the derived Bonsplit presentation in `TabItem`

It is a render cache, not canonical truth. Persisting it risks restoring stale violet/motion state before the metadata-backed attention index hydrates. Prefer an optional non-authoritative field defaulting to nil on decode, recomputed by c11 after restore, unless a concrete live-transfer path truly requires encoding.

### 3.8 Codex only — `by: operator | agent` has no trust model

Is it authorization data or descriptive provenance? Nothing stated prevents an agent socket client from claiming `operator`. If it is provenance, say so explicitly; otherwise define how it is authenticated. (This directly conditions Claude's G2 fix in 1.2 #9 — "operator-originated raises don't notify" is only safe if `by` can't be spoofed, or if the origin is derived from the call path rather than the payload.)

### 3.9 Codex only — tagged validation has no quit/resume cycle

The plan requires persistence but the tagged-validation flow never quits and relaunches. Logic restore tests are valuable but will not catch service hydration or stale-presentation issues. Needs a real tagged relaunch with an active flag, a revised reason, and a suppressed unread record. *(This aligns with the repo's own "green tests ≠ working product" doctrine.)*

### 3.10 Codex only — transfer/detach contract is named but not specified

A detached flagged surface must preserve reason *and* epoch while changing workspace ownership, and the source index must not briefly leave a stale queue entry.

### 3.11 Gemini only — banner z-order fragility

The plan says the banner must define its z-order against find, pane-interaction, notification-ring, and others. Managing z-index across multiple independent AppKit portal overlays hosted from different sources is fragile and regression-prone. Gemini asks whether c11 has centralized z-index management for overlays or whether this will rely on implicit sibling order / hardcoded indexes. **Worth noting the repo's own CLAUDE.md records a related hazard** (portal-hosted terminal views sitting above SwiftUI during split/workspace churn, which is why `SurfaceSearchOverlay` must mount from `GhosttySurfaceScrollView`), so this is a live class of bug here, not a theoretical one.

### 3.12 Gemini only — Bonsplit push destination

The plan says push to remote `main`. Gemini asks whether that means the `Stage-11-Agentics/bonsplit` fork's main, or whether an upstream PR to `almonk/bonsplit` must merge before the parent pointer updates. A one-line clarification that unblocks the submodule step.

### 3.13 Claude only — `flag.raised` carries no `by`, making the event taxonomy asymmetric

`flag.lowered`, `flag.suppressed`, and `flag.unsuppressed` all carry `by`; `flag.raised` does not — despite the spec's emphasis that "a flag arrives from either side." An Overwatch consumer tailing events therefore cannot distinguish "the operator flagged this mission at dispatch" from "the agent hit a blocker," which are completely different routing decisions. Looks like a spec oversight. Adding the field now is free; adding it later is a compat problem.

### 3.14 Claude only — `flag.list` has no CLI counterpart

Phase 2 adds five socket methods and CLI commands for four. There is no `c11 flags` / `c11 list-flags`, and the staged skill section documents none. An orchestrator that dispatched a fleet has a push stream (events) and a socket method it cannot reach from the shell. A read command is not a dashboard, so this doesn't violate the stated non-goal. Add `c11 flags [--json]` in Phase 2 plus a skill line.

### 3.15 Claude only — the second `WorkspacePulseProjector.project` overload

`SidebarActivityProjector.swift` carries a second `project(hasWorkspaceDemand:surfaceStates:...)` overload taking bare `[WorkspacePulseState]` with no agent records and therefore no modifiers. If live, it is a path where flags and suppression silently do not apply. The plan should say whether it is dead, needs the modifier fields, or is intentionally modifier-free.

### 3.16 Claude only — a restored cold flagged surface holds the head of the queue forever

Flags are canonical metadata and survive relaunch. A flagged agent whose process is long gone restores as flagged-and-cold, breathing violet, and sits at the head of the oldest-first queue permanently (it *is* the oldest). ⌥V sends the operator to a dead surface first, every time, until manually lowered. The plan's "skip stale/unopenable surfaces" does not cover this: a *restorable* surface is not a *stale* one. Needs an explicit call — leave it at the head per the sticky contract, or deprioritize (not skip) cold flags.

### 3.17 Claude only — "extend the resolver **or** a sibling reducer" must be decided

The plan says "or." Two reducers that must agree is precisely the failure mode the plan's own risk register names ("spec precedence implemented differently in two renderers"). Extend `SurfaceTabActivityResolver` so exactly one function maps (lifecycle, unread, flag, suppression) → presented state, consumed by both `WorkspacePulseAgent.presentedState` and the Bonsplit tab path.

### 3.18 Claude only — the commit boundary spans two isolation domains and the reconciliation is unstated

"One serialized commit boundary" and "never use `DispatchQueue.main.sync`" are in tension: the commit spans the metadata store's serial queue (off-main) and the main actor (projection, notification store, `UNUserNotificationCenter`, banner host). The resolution is almost certainly an explicit asynchronous continuation — serial-queue write, `async` hop to main, socket response resolved from a completion at the *end* of the main phase — but "almost certainly what the author means" is not a design an implementer can execute without re-deriving it, and re-derivation is where `main.sync` sneaks back under deadline pressure. Needs: what object holds pending socket responses; what happens when a second mutation for the same surface arrives mid-hop (the idempotency rules imply a per-surface pending-op key, not a global queue); and the response contract if the main hop never runs (app terminating).

### 3.19 Claude only — event-vs-projection visibility ordering

If `flag.raised` is emitted from the serial queue while projection happens on main, an Overwatch consumer can observe the event *before* `flag.list` reflects it. For a feature whose stated integration story is "events are the Overwatch integration," that read-your-writes gap matters. Either emit from the main-actor tail of the commit, or state explicitly that events lead the projection and consumers must tolerate it.

### 3.20 Claude only — the CI-only inner loop compounds with PR size

The operator's no-local-`xcodebuild-test` constraint (including `c11-logic`) is explicit and not relitigated, but the plan should acknowledge the consequence: the inner loop for a 22-file cross-cutting change becomes a CI round-trip. Claude credits the plan's compensating move — `build-for-testing` as a link/membership check with an explicit warning not to treat it as assertion evidence — as exactly right.

---

## 4. Consolidated Questions for the Plan Author

Deduplicated across all three reviews and grouped. Attribution in brackets: **[C]** Claude, **[X]** Codex, **[G]** Gemini. Multi-model attribution indicates independent convergence.

### A. Decisions that must be made before Phase 0 (they freeze contracts or strings)

1. **On a suppressed surface, does a flag raise send a system notification — yes or no?** And which document becomes authoritative afterward? The plan currently pre-accepts "yes" in validation item 8 and the acceptance checklist while its held-decision section reads the spec as "no," and the binding spec says suppressed surfaces deliver no system notification by definition. All of spec, matrix, validation steps, acceptance checklist, and tests must then be made to agree. **[X, C]**
2. **Should `launch-agent --flag` fire a system notification at all?** Both reviewers who raised it say no — a launch-time flag is a watch marker, not an interrupt. Should *all* operator-originated raises skip direct delivery, or only launch-time ones? Keep this as a condition independent of Q1's suppression branch, not a tangled predicate. **[C, X]**
3. **Does a launch-time mission flag remain raised through ordinary completion**, until explicitly lowered, even when no human blocker ever arose? **[X]**
4. **Should generic `surface.set_metadata` / `clear_metadata` / `replace` be forbidden from mutating `flag` and `suppressed`, or remain first-class mutation routes?** If they remain allowed, specify: what `by` value they emit; how an active reason revision preserves its epoch; how a mixed ordinary-plus-attention replace commits atomically; what happens when precedence rejects one attention key and accepts another; and whether clear-all lowers a flag, emits `flag.lowered`, and with which actor. **[X, C]**
5. **What happens to the "Jump to Latest Unread" copy?** Rename across all six locales, or keep the label and accept it now sometimes means something else? Related: should the menu item be *enabled* when a flag exists but signal-eligible unread count is zero? And should the Notifications-page button stay notification-only, or take the unified prioritized jump? **This must be settled in Phase 1 so strings freeze before the Phase 6 translator stage.** **[C, X]**
6. **Should `flag.raised` carry `by`?** Three of four attention events carry provenance and the spec insists flags arrive from both sides. Was the omission deliberate, or inherited spec oversight? **[C]**
7. **Is `by: operator | agent` trusted authorization data or descriptive provenance?** What prevents an agent socket client from claiming `operator`? (Conditions the safety of Q2's fix.) **[X]**
8. **One PR or three?** The plan's own commit-unit list already decomposes into three independently shippable, independently reviewable PRs. Was single-PR deliberate — and if so, against what: atomicity of the skill contract, or coherence of each landed operator-facing state? **[C vs. X — genuine disagreement]**

### B. The commit boundary and state durability

9. **What is the concrete ordering primitive for the attention commit?** Which object holds pending socket responses; what happens when a second mutation for the same surface arrives while the first is mid-main-hop; and what is the response contract if the main hop never runs (app terminating)? **[C]**
10. **Do events lead or trail the projection?** Can an Overwatch consumer observe `flag.raised` before `flag.list` reflects it? If yes, is that acceptable and documented? **[C]**
11. **Is the metadata source timestamp definitively the public flag epoch, and may an attention-specific store write preserve it while changing the reason?** `setMetadataLocked` preserves `SourceRecord.ts` only for an identical same-source write (`SurfaceMetadataStore.swift:725-742`), so a revised reason currently loses the epoch on relaunch. Which durable mechanism: preserve the sidecar timestamp through an explicit attention transaction, or a canonical `flag_raised_at` key? **[X]**
12. **What exact published value invalidates the UI when signal eligibility changes but `notifications` does not?** An explicit published signal snapshot, a monotonic `signalRevision`, or something else — and is publication part of the attention commit? **[X]**
13. **During cross-workspace/window detach and attach, must the flag queue age remain unchanged and globally ordered throughout the transfer?** **[X]**
14. **What is the test injection seam for flag raise timestamps?** Validation scenario 9 needs two flags with controlled raise times to prove oldest-first ordering. Does the pure selector take timestamps as parameters, or does the service take an injectable clock? Without one, the test degrades to "raise, sleep, raise" — flaky. **[C]**

### C. Notification-store split and navigation

15. **Which current consumers are intentionally raw-history consumers, and which must migrate to signal eligibility?** Please produce the API ownership table, including the direct raw-array consumers in `ContentView`, `WorkspaceContentView`, `c11App`, `UpdateTitlebarAccessory`, and `AppDelegate`. **[X]**
16. **Should focusing a suppressed surface continue to mark its raw notification record read**, even though that record contributes no signal? **[X]**
17. **Does the menu-bar unread count stay signal-eligible notification count**, rather than being overloaded with flag count? **[X]**

### D. Rendering, dominance, and accessibility

18. **What type represents "flagged dominates waiting" while `WorkspacePulseState` stays four cases?** A separate dominance type, a `(state, flagged)` value, or `dominantAgent` plus derived presentation — and who are the consumers? **[X]**
19. **Must the full flag reason be announced on both the Bonsplit surface tab and the sidebar mark**, or is "Flagged" sufficient on marks with the banner carrying the reason? Either way, neither renderer payload currently carries the reason — what carries it? **[X]**
20. **`SurfaceTabActivityResolver` extension or sibling reducer?** The plan says "or." Which — and how do you guarantee the sidebar and the tab chip cannot disagree? **[C]**
21. **Should the generic Bonsplit presentation be encoded in `TabItem`**, or default to nil on decode and always rehydrate from c11 metadata after restore? **[X]**
22. **Is the second `WorkspacePulseProjector.project(surfaceStates:)` overload live?** If so, does it need modifier support, or is it intentionally modifier-free? **[C]**
23. **Will `Workspace.syncSurfaceTabActivityStateForPanel`'s early-return guard be widened to compare the full presentation value?** As written it swallows a flag raised mid-working — the plan's own headline scenario #2 — because neither `activityState` nor the badge changes. Will there be a named regression test? **[C]**
24. **Does c11 have centralized z-index management for AppKit portal overlays**, or will the banner rely on implicit sibling order / hardcoded indexes against find, pane-interaction, and the notification ring? **[G]**

### E. Direct system-notification lifecycle

25. **What stable identifier do direct flag notifications use**, and should a reason revision *replace* the prior OS notification rather than appending a second one? **[X, G]**
26. **Does lowering remove pending and/or delivered flag notifications** from Notification Center, or do delivered ones remain as historical OS artifacts? **[G, X]**
27. **After a raise, what should a later suppress/unsuppress do to a pending direct flag notification** under the chosen Q1 delivery policy? **[X]**
28. **Do active-to-active reason revisions need debouncing or rate-limiting** to stop an agent streaming its reasoning into the reason field from spamming Notification Center? (Q25's stable identifier may make this moot — confirm.) **[G]**
29. **Can "delivery completes before the socket response" be restated precisely?** `UNUserNotificationCenter.add` is asynchronous; the commit can guarantee scheduling was enqueued, not that macOS delivered the banner. **[X]**

### F. Surface area, scope, and validation

30. **Is `flag.list` process-global across all windows and workspaces, scoped to the addressed window, or filterable?** And relatedly: is the Flagged Agents row's count app-global while the sidebar it lives in is workspace-scoped? If the operator is in workspace A and the only flag is in workspace B, the row appears in A and the jump navigates away — intended? **[C, X]**
31. **Which machine-readable list responses gain attention fields — only `flag.list`, or `surface.list` too?** **[X]**
32. **Is there a `c11 flags [--json]` CLI read command?** If not, how does an orchestrator poll its fleet's flag state from the shell, given the socket method has no CLI counterpart and the staged skill documents none? **[C]**
33. **What clears a flag when a surface is closed?** Does closing a flagged surface emit `flag.lowered`, and with what `by`? An Overwatch consumer tracking open flags needs the close to be observable. **[C]**
34. **Should a restored cold flagged surface hold the head of the oldest-first queue indefinitely?** "Skip stale/unopenable" does not cover restorable-but-dead. Deprioritize cold flags, or leave them at the head as the sticky contract implies? **[C]**
35. **How do you measure keystroke-to-paint p50/p95 at 1 ms resolution?** No harness exists in the repo. Is building one in scope as a named deliverable, or should the gate be restated in proxies — `BonsplitDebugCounters` body-eval counts, shared-clock subscriber count, sustained-typing CPU — plus a subjective pass on a controlled 20-agent build? **[C]**
36. **Must tagged runtime validation include a real quit/resume cycle** for an active flag, a revised reason, and a suppressed unread record? **[X]**
37. **Does the 256-character reason cap count grapheme clusters after trimming/normalization, and should every Unicode newline separator be rejected (not only LF)?** And is hard rejection the right failure mode — a 300-character reason strands an agent that is *already blocked*. Consider truncate-with-warning, or at minimum state the cap in the error message so a retry can succeed. **[X, C]**
38. **Where does the Bonsplit submodule commit get pushed** — `Stage-11-Agentics/bonsplit` main, or does an upstream PR to `almonk/bonsplit` need to merge before the parent pointer updates? **[G]**
39. **What is the fallback if the Bonsplit change turns out to need a c11-specific concept after all?** If violet + alternate core + explicit motion cannot be expressed generically without contortion, is the answer to contort, or to accept a scoped, documented divergence? **[C]**

---

## 5. Overall Readiness Verdict

### 5.1 Synthesized verdict

**Needs revision — architecture accepted, contracts unfinished.** 2 of 3 reviewers, and both of the two that verified against the tree.

The plan should not be re-planned and should not begin Phase 0 as written. The gap between it and executable is roughly ten contract amendments plus one packaging decision, none of which touch the model.

### 5.2 What each model would need to flip to Ready

| | Claude | Codex | Gemini |
|---|---|---|---|
| Verdict | Needs revision | Needs revision | Ready |
| Blocking count | 6 | 7 | 0 |
| Framing | "Revision measured in hours, not a rethink" | "Contract amendments, not a redesign" | "Minor gaps handled during implementation" |
| Code verified | ~12 files, all claims held | Line-level (`:725-742`) | None cited |

### 5.3 Consolidated blocking list (union, deduplicated)

Ordered by when it must be resolved.

**Before Phase 0 — contract decisions:**

1. **Resolve the suppressed + flagged direct-delivery decision**, then reconcile spec, matrix, validation steps, acceptance checklist, and tests so the plan has exactly one acceptance outcome. *(Q1)*
2. **Specify the durable epoch-preservation write primitive** for active-to-active reason revisions. The semantic the plan states as settled is not representable under the current store. *(Q11)*
3. **Decide route-vs-reject for generic attention metadata writes**, and if routed, specify `by` derivation, epoch preservation, mixed-replace atomicity, partial-precedence behavior, and clear-all semantics. *(Q4)*
4. **Rule that operator-originated raises do not fire a direct system notification**, kept independent of the suppression branch — and settle the `by` trust model that makes the rule safe. *(Q2, Q7)*
5. **Decide PR packaging** (one vs. three) and record the reason. *(Q8)*
6. **Freeze the "Jump to Latest Unread" copy and enablement decision in Phase 1**, before the six-locale translator stage. *(Q5)*

**Before Phase 1 — design specification:**

7. **Specify the commit-boundary ordering primitive**: pending-response ownership, concurrent per-surface mutation behavior, main-hop-never-runs contract, and event-vs-projection visibility ordering. *(Q9, Q10)*
8. **Define the signal-index publication mechanism** plus the raw-vs-signal API ownership table and per-caller migration list. *(Q12, Q15)*
9. **Define the typed dominance result** and **carry the flag reason into both renderers' accessibility models**. *(Q18, Q19)*
10. **Specify direct-notification identity and lifecycle**: stable per-surface-per-epoch identifier, revision replacement, lower/suppress cleanup, launch behavior, and precise async-scheduling wording. *(Q25–Q29)*

**Before Phase 4 — validation instrumentation:**

11. **Fix the latency gate**: scope the keystroke-to-paint harness as a named deliverable, or restate the threshold in measurable proxies. No instrument currently exists in the repo. *(Q35)*

**Named code-level defects to close during implementation:**

12. `Workspace.syncSurfaceTabActivityStateForPanel` early return, with a regression test. *(Q23)*
13. `SurfaceTabActivityResolver` — extend, do not fork. *(Q20)*
14. The second `WorkspacePulseProjector.project` overload — classify it. *(Q22)*

### 5.4 Strongly recommended, non-blocking

15. Add `by` to `flag.raised` while it is still free. *(Q6)*
16. Add `c11 flags [--json]` plus a skill line. *(Q32)*
17. Specify the timestamp injection seam for ordering tests. *(Q14)*
18. Add a real quit/resume cycle to tagged validation. *(Q36)*
19. Decide cold-flag queue priority. *(Q34)*
20. Do not encode the derived Bonsplit presentation in `TabItem`. *(Q21)*
21. Clarify the Bonsplit push destination before the submodule step. *(Q38)*

### 5.5 Closing note on the pack

The union of blocking findings is 11 items; the intersection across all three reviewers is **zero**. Every blocking finding in this synthesis was surfaced by one or two models, never all three. The two deepest findings — the non-representable flag epoch and the missing signal-index publication — came from a single reviewer each, and both would have shipped as bugs under any single-model review. The three-model pack paid for itself here.

The corollary is a caution about the outlier: Gemini's "Ready to execute" is the only verdict produced without opening a source file, and its reading of the suppressed + flagged rule as *already settled* is direct evidence that the plan's contradictory acceptance criteria will mislead a real implementer. That misreading is not a mark against Gemini so much as a finding about the document.
