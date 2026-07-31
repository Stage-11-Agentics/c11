# Standard Plan Review — c11-185-plan (Claude)

- **Plan under review:** `.lattice/plans/task_01KYQYND86DZMKGR58BJ4Y3R53.md` (C11-185)
- **Contract:** `.lattice/plans/c11-185-plan-review-pack-2026-07-29T1828/context-task-spec.md`
- **Reviewed:** 2026-07-29 18:33 local
- **Base verified:** worktree `c11-worktrees/c11-185-agent-activity-details` @ `23e2fd375`, contains `f5f4dbcbf` (C11-184 / PR #387, merged 2026-07-29T00:33Z). Two commits behind `main` (`78e348c74`).

---

## Executive Summary

The plan is **directionally correct and structurally wrong for the job it has to do**. Every one of its six steps points at a real seam, in a sensible order, and it correctly identifies the two things that most plans of this shape get wrong: reuse the shared projection rather than re-deriving lifecycle per renderer, and separate structured Surface Details capture from the mutable metadata JSON. That is genuine architectural judgment, not boilerplate.

But it is eight lines standing in for a locked contract with 12 acceptance criteria, six named performance guardrails, a submodule push ordering gate, and a seven-locale translation pass. Its sibling C11-184 plan is ~520 lines for comparable surface area, and that length was not padding — it was the product of a review cycle that discovered exactly the class of trap this plan re-opens. C11-185's plan reads like a *table of contents for a plan* rather than the plan.

That would be a stylistic complaint if the terseness were uniform. It isn't. The compression has silently swallowed **three specific things I verified against the code, each of which is sufficient to fail an acceptance criterion or regress a protected hot path**:

1. **`Working for N minutes` has no data source in the codebase, and the plan never creates one.** `derivedActivityBySurface` is `[UUID: SidebarActivityState]` — a bare enum, no entry timestamp. `coldAgentSurfaceIds` is a bare `Set<UUID>`. `SurfaceActivityTracker` stores one continuously-overwritten `lastActivity` per surface, so `now - lastActivity ≈ 0` *while* an agent is working. Idle, cold, and waiting durations are all derivable from what exists (`lastActivity`; `lastActivity + threshold`; `TerminalNotification.createdAt`). **Working-state-start does not exist anywhere.** The plan's step 3 promotes only `createdAt`; nothing adds a lifecycle-transition stamp. Because the contract also says "if no trustworthy state-start timestamp exists, show the localized state alone," an implementer can ship a bare `Working` tooltip and *technically pass criterion 2* while gutting the ticket's own headline example. This is the single most important gap in the plan.

2. **Step 2's "precompute it for ... `WorkspacePulseAgent`" is, read literally, a fleet-wide typing-latency regression.** `WorkspacePulseSummary` is `Equatable` and holds `agents: [WorkspacePulseAgent]`; `ContentView`'s sidebar `TabItemView.==` compares `lhs.workspacePulse == rhs.workspacePulse` (line 11745) and the call site relies on `.equatable()` to skip body re-evaluation during typing. Put a *formatted duration string* in `WorkspacePulseAgent` and the comparison flips every time any agent's minute rolls over, invalidating the whole workspace row — the precise defense CLAUDE.md names as load-bearing. The fix is not subtle (carry stable `Date?` values, format at the leaf), but the plan does not distinguish "precompute the projection" from "precompute the string," and the wrong reading is the shorter one.

3. **Step 5's Bonsplit ordering gate is missing its precondition, and the repo is currently in the exact state that punishes the omission.** The plan says push to bonsplit `main` before the parent pointer. It does not say *check out `main` first*. `vendor/bonsplit` is **DETACHED right now** in both the primary checkout and the C11-185 worktree. An implementer following step 5 verbatim commits on a detached HEAD, pushes nothing, and orphans the commit. C11-184's plan carried this as an explicit Phase-0 step *and* as a logged plan-review resolution; C11-185 dropped it.

**Verdict: needs revision** — not rethinking. The bones are right. It needs the working-state-start decision made explicitly, the churn boundary stated, and roughly four dropped preconditions restored.

---

## The Plan's Intent vs. Its Execution

The intent is clear and worth restating because the plan never does: **make the new mark vocabulary self-teaching.** C11-183 gave lifecycle a shape; C11-184 gave attention two modifiers. Both are now unlabeled glyphs the operator must have read a skill file to decode. C11-185 attaches language to the glyph at the two places a human looks — hover, and right-click → details — and it commits to those two surfaces agreeing. That is a coherent, high-leverage piece of work and the plan's ordering serves it.

Where execution drifts from intent:

**The plan optimizes for its own brevity, not for its reader.** The audience is a fresh agent in an isolated worktree with no memory of the C11-183/184 runs. That reader needs to know *where the numbers come from*. The plan tells it *which files to touch*. Those are different documents. "Add behavior-level coverage for state-start arithmetic" presumes the arithmetic's inputs exist; I checked, and for one of four states they don't.

**"Without changing lifecycle inference" (step 1) is doing more work than it should.** As a scope fence it is exactly right — do not reopen C11-183/184. But adding a transition timestamp beside `setDerivedActivity` (which its own comment advertises as "Cheap and I/O-free" — an ideal stamping site) *is* touching the inference path, even though it changes no inferred state. A cautious implementer reads step 1 as forbidding the one change the feature needs. That ambiguity should be resolved in the plan, in favor of "stamping a transition time is not changing inference."

**Step 6 inverts the usual failure and deserves credit.** Most terse plans stop at "open PR." This one ends at tagged QA with dialogs suppressed, hover evidence for all three mark locations, `pr_open`, no merge. It even remembers that computer-use approval is separately requested — which is the live lesson from C11-184, where approval was withheld and both visual gates shipped deferred. That is institutional memory functioning correctly.

---

## Architectural Assessment

### The decomposition is right

Six steps map to: baseline → pure projection → persistence → tests → submodule/localization → validation. Pure logic before rendering, persistence isolated from presentation, submodule before parent pointer, validation last. I would arrive at the same shape.

Two specific calls are better than they look:

**One projection consumed by both tooltip and Surface Details (step 2, arch item 1).** The alternative — each renderer formats its own copy from raw state — is the default, and it is how "Activity" and the tooltip end up disagreeing by one minute and nobody can reproduce it. Criterion 5 ("state duration agrees with the tooltip for the same surface at the same clock instant") is only cheaply testable because of this choice. It also makes the hardest assertion a *pure* one, which matters given the operator's standing prohibition on local `xcodebuild test` in this repo.

**Structured details capture separate from metadata JSON (step 3, arch item 6).** The tempting shortcut is to write `created_at` / `last_activity` into `SurfaceMetadataStore` so Surface Details renders them for free from the existing JSON blob. That would be a real mistake — it turns a display concern into agent-visible API surface, pollutes `get-metadata`, and makes derived UI facts persist as if they were declared truth. Explicitly refusing it is the correct instinct.

### Where the structure has a hole

**There is no step 0.** C11-184's plan opened with an ancestry-and-provisioning gate. C11-185 has none: no base commit, no `git submodule update --init --recursive`, no GhosttyKit symlink check, no worktree creation — despite the contract's guardrail "implement from an isolated worktree" and a primary checkout where `Sources/ContentView.swift` (a file this ticket must edit) carries 206 lines of uncommitted operator changes. Operationally the worktree already exists and is provisioned, so this is currently benign; it is a landmine on any reset or re-run, and this plan has already been reset three times per its C11-184 sibling's tail.

**Step 3 conflates two independent persistence problems.** `createdAt` needs a new `Panel` property, a new `SessionPanelSnapshot` field with `decodeIfPresent`, and threading through three fresh-create plus three restore paths — a mechanical, high-touch, low-risk change. "Capture structured Activity/Created/Last activity data for Surface Details" is a *seam design* problem: `SurfaceManifestSnapshot.capture(workspaceId:surfaceId:)` today takes only two UUIDs and reads `SurfaceMetadataStore.shared`. To add `createdAt` it must reach a `Panel`; to add last-activity it must reach `SurfaceActivityTracker`. Who performs that lookup, and how it stays injectable enough to unit-test criterion 5, is an unanswered design question sharing a bullet with a rote refactor. They should be separate steps.

**Nothing addresses `.help()`'s eagerness.** The contract says "refresh tooltip copy on hover entry." SwiftUI's `.help(_:)` takes a `String` **eagerly at body-build time** — there is no lazy variant. So "refresh on hover" requires either (a) a leaf `@State helpText` updated from `onHover`, or (b) an AppKit `NSView.toolTip` set via a representable, or (c) accepting a string built at sync time and stale between syncs. The plan picks none, and this is not a free choice: `TabBarView.swift:1034` carries an in-repo warning that *"A child `.onHover` here would create an AppKit hosting layer that swallows the mouse-down — that mistake is why the tap broke once."* Option (a) inside the tab is the documented way to break acceptance criterion 4 (tab selection unchanged). Option (c) breaks criterion 5 (agreement at the same clock instant) and re-raises the churn problem if you refresh the payload to keep it fresh. This is the plan's central unforced technical decision and it is invisible in the current text.

### Alternative framing worth naming

A stronger framing than "add tooltips" is **"add one `SurfaceActivityFacts` value type — four optional `Date`s plus modifier facts — and give it two renderers."** Under that framing:

- The type is `Equatable` over stable `Date`s, so putting it in `WorkspacePulseAgent` is *safe* by construction: it does not churn on clock ticks. Weakness #2 disappears architecturally rather than by discipline.
- "Where does each `Date` come from?" becomes four explicit questions, and the working-start hole surfaces in the first five minutes instead of in review.
- Formatting is one pure function `(facts, now, locale) -> String`, trivially unit-testable, and the "hover freshness" question collapses to "who calls the formatter, and with what `now`" — a small, local, honest decision.
- Surface Details needs no new capture plumbing beyond the same value, arriving by the same route.

The plan's architecture section is *nearly* this (arch item 1 lists "presented lifecycle, optional state-start time, optional last-activity time, flag reason and raised time, and suppression" — the right fields). The plan then loses it in step 2 by talking about composing localized strings rather than carrying dates. **Recommendation: state the boundary explicitly — dates cross the model boundary, strings are built at the leaf.** One sentence, and two of my three top findings become structurally impossible.

---

## Is This the Move?

Yes, and the sequencing bet is right. Labeling a vocabulary you just shipped is higher-leverage than shipping more vocabulary, and doing it while C11-183/184 are fresh means one agent holds all three models at once.

Two bets I'd re-examine:

**Betting on a locked contract to substitute for plan detail.** The contract is unusually good — it pins duration semantics per state, forbids `0 minutes`, names `Last activity` over `Last action`, and defines what `Created` is *not*. A plan can reasonably lean on that and avoid restating it. But a contract states *what must be true*; a plan must state *how it becomes true*. The plan leans on the contract for the parts the contract cannot cover: data availability, churn boundaries, and preconditions. Those are precisely the three places it broke.

**Betting that C11-184's lessons carry implicitly.** They don't — a fresh worktree agent reads this plan, not #387's history. The detached-submodule gate, the "no local xcodebuild test" prohibition (which CLAUDE.md and memory both record as an explicit operator interruption on C11-181), and the single-tagged-launch rule were all *earned* in the sibling run and are all absent or vague here. Step 4's "Run focused safe logic/host tests and build checks" is the most dangerous line in the plan: it reads as permission to run `xcodebuild test`, which is exactly what the operator has interrupted before in this repo.

---

## Key Strengths

1. **One projection, two consumers.** Makes the cross-surface agreement criterion cheap and pure. Reflects the principle that if two surfaces must agree, they should share a value, not a rule.
2. **Refuses to launder derived UI facts through `SurfaceMetadataStore`.** Keeps a display feature from becoming permanent agent-visible API. The kind of restraint that is invisible when it works and expensive when it's missing.
3. **Correct scope discipline on the mark locations.** Top-tab mark plus the two individual sidebar mark locations; explicitly *not* the aggregate composition rail. Verified against the code: `workspacePulseSummaryRow` (12032) and the census mark row (12183) are the individual locations, `workspacePulseCompositionRail` (12255) is the aggregate. Tooltipping the rail would be semantically wrong (which agent is it describing?) and the plan gets this right without belaboring it.
4. **Bonsplit stays generic.** "Extend `BonsplitTabActivityPresentation` with generic help data" and let c11 own flagged/suppressed semantics. This is the fork-discipline rule from CLAUDE.md applied correctly, and the existing struct already proves the pattern works — it carries `accessibilityValue: String?` for exactly this reason. Adding `helpText: String?` beside it is a two-line, upstreamable change.
5. **Escapes forward to validation.** Tagged QA with dialogs suppressed, three-location hover evidence, `pr_open`, no merge. Correctly anticipates the approval gate rather than discovering it.
6. **Ordering instinct on the submodule.** The *idea* in step 5 is right even though its precondition is missing.

---

## Weaknesses and Gaps

Ordered by expected cost.

### 1. Working-state-start has no source (blocks criterion 2) — **high**

Verified: `Workspace.derivedActivityBySurface: [UUID: SidebarActivityState]` (line 5503) carries no timestamp. `coldAgentSurfaceIds: Set<UUID>` (5509) carries no crossing time. `SurfaceActivityTracker.lastActivity` is overwritten on every input.

| State | Source available today? | Notes |
|---|---|---|
| Idle | Yes — `lastActivity` | Direct |
| Cold | Yes — `lastActivity + SidebarAgentColdSettings.thresholdSeconds()` | Derivable; matches the contract's "not total idle time" |
| Waiting | Yes — `TerminalNotification.createdAt` (line 647) | Exact, as contract requires |
| **Working** | **No** | Nothing records lifecycle entry |

*Downstream:* the implementer either (a) invents something (worst: `lastActivity` as working-start, which reads ~0 and produces the forbidden `0 minutes`), or (b) ships bare `Working`, passing the letter of criterion 2 while the ticket's first example never renders. The minimal honest fix is a `[UUID: Date]` transition stamp written in `setDerivedActivity` when the state actually changes — cheap, main-actor, I/O-free, and the function already isolates the changed-vs-unchanged branch. **The plan must decide this, not leave it.** Related unasked question: should working-start survive restart? (I'd argue no — "Working for 3 days" across a reboot is a lie — but the contract is silent and step 3 persists only `createdAt`.)

### 2. Formatted strings in an `Equatable` hot-path payload — **high**

Verified: `TabItemView.== ` at `ContentView.swift:11736-11756` includes `lhs.workspacePulse == rhs.workspacePulse`; `WorkspacePulseSummary` holds `agents: [WorkspacePulseAgent]`; the call site uses `.equatable()`. `WorkspacePulseProjector.project` runs inline in the sidebar `ForEach` (≈8690) on every parent evaluation.

*Downstream:* a ticking duration string inside `WorkspacePulseAgent` makes the equality check flip on a minute boundary for every workspace row with an agent, defeating the documented typing-latency defense across the whole fleet. Worse, it is the kind of regression that shows up as "typing feels bad with 20 agents" three releases later, with no obvious culprit. Note the trap's shape: the contract's guardrail says "precompute immutable payloads in the existing parent/state-sync paths," and this satisfies the *letter* (precomputed in the parent) while violating the *intent* (no churn). **Fix: carry `Date?`s across the boundary; format at the leaf.**

### 3. Bonsplit gate missing its precondition, submodule detached now — **high**

Verified: `git -C vendor/bonsplit symbolic-ref --short HEAD` → **DETACHED**, in both the primary checkout and the C11-185 worktree.

*Downstream:* commit on detached HEAD → orphaned commit → parent pointer references an unreachable SHA → CI fails on the checksum/pointer path, and the fix is a re-do. CLAUDE.md names this pitfall explicitly; C11-184's plan gated it in Phase 0 and logged it as a review resolution. **Fix: `cd vendor/bonsplit && git checkout main && git fetch origin && git merge --ff-only origin/main`, verify `symbolic-ref --short HEAD == main`, then commit/push, then `git merge-base --is-ancestor HEAD origin/main` before the parent pointer.**

### 4. `.help()` eagerness vs. `.onHover` hazard vs. accessibility duplication — **high (as a cluster)**

Three interacting facts the plan does not mention:

- `.help(_:)` is eager; "refresh on hover entry" is not achievable with it alone.
- `TabBarView.swift:1034` documents that a child `.onHover` inside the tab creates a hosting layer that swallows mouse-down — the documented way to break criterion 4.
- `TabItemView` is already `.accessibilityElement(children: .combine)` with `.accessibilityValue(accessibilityValue)` (which already folds in `presentation.accessibilityValue` — i.e. C11-184's `Flagged: <reason>`) and `.accessibilityHint(activityAccessibilityHelp)`. `TabActivityMarkLeaf` is `.accessibilityHidden(true)`.

*Downstream:* a `.help()` on a child of a combined accessibility element may be absorbed, reordered, or duplicated against two existing channels — directly against the contract's "without duplicating values already exposed by the tab." Criterion 8's "rendered accessibility composition through executable paths" is the right test, but the plan should state the *intended* composition so the test has something to assert. Good news the plan can lean on: the mark already sits inside a fixed-size `HStack` with `Color.clear` pads and an explicit `.frame(width: leadingAccessoryWidth, height: tabItemHeight)` (TabItemView.swift ≈737-775) — the padded hit area the contract asks for **already exists**, so a `.help()` on that container needs no geometry change at all. Worth naming, since it makes criterion 4 nearly free.

### 5. `SurfaceActivityTracker.lastActivity` is `queue.sync` — **medium**

Verified (`SurfaceActivity.swift:60-66`): the read does a synchronous hop onto a serial utility queue. The contract already forbids reading the tracker in typing-hot bodies, but the plan's chosen home — the sidebar roster build — runs on every parent evaluation, and a `queue.sync` **per agent** there is a serialized round-trip × N agents × every re-eval, on a `.utility`-QoS queue (priority inversion risk from the main thread). *Fix:* one bulk snapshot per sync (add a bulk read to the tracker, mirroring the existing `seed(from:)`) rather than N point reads.

### 6. Timestamp format lacks a timezone — **medium**

Verified: `SurfaceManifestView.timestampFormatter` is `dateFormat = "yyyy-MM-dd HH:mm:ss"` — no zone. The contract requires "absolute timestamps include timezone" and its example shows `2026-07-29 14:31:05 EDT`. Reusing the existing formatter silently fails that. *Also unresolved:* the contract says the existing `Captured` row "remains separate" — does it now also gain a timezone (consistent, but a visible change to an untouched row), or do two formats coexist in one panel? Plan is silent; either answer is defensible, one must be chosen.

### 7. "Run focused safe logic/host tests and build checks" — **medium**

CLAUDE.md and operator memory both record local `xcodebuild test` as prohibited for this repo during delegator runs, *including* the nominally-safe `c11-logic` scheme (C11-181, operator interrupted). C11-184's plan spelled this out in a dedicated section. "Run focused safe logic/host tests" reads as the opposite instruction. This will cost an operator interruption. *Fix:* restate C11-184's rule — author coverage, compile with `build-for-testing`, let PR CI execute assertions.

### 8. No base gate / no step 0 — **low-medium**

No base commit, no submodule/GhosttyKit provisioning, no worktree creation, despite a guardrail requiring worktree isolation and a primary checkout with 206 uncommitted lines in `Sources/ContentView.swift`. Currently benign (worktree exists and is provisioned, `f5f4dbcbf` is an ancestor, 2 commits behind `main`), but this plan has been reset before and a reset re-runs step 1, not the environment.

### 9. Bonsplit mark call-site inventory incomplete — **low**

There are **two** `TabActivityMark(` call sites: `TabItemView.swift:742` (the tab's leading accessory) and `TabBarView.swift:1238` (`collapsedActivityMark`, the collapsed/overflow control chip). The plan says "the top-tab mark," singular. The contract excludes the aggregate composition rail (a c11 sidebar view) but says nothing about the collapsed chip, which is a third, genuinely ambiguous location — it represents the *active* tab plus background-waiting, so it is neither clearly individual nor clearly aggregate. C11-184's plan remembered to say "and any alternate/compact tab-bar mark call sites." Needs a stated decision.

### 10. Localization scope understated — **low**

Step 5 says "delegate the final six-locale translation pass." Verified: `vendor/bonsplit/Sources/Bonsplit/Resources/` has **seven** `.lproj` catalogs (en, ja, ko, ru, uk, zh-Hans, zh-Hant), and the contract requires "Bonsplit activity labels remain localized in all seven." So there are two catalogs to feed — c11's `Localizable.xcstrings` and Bonsplit's `.lproj` set — with different formats and different validators (`jq` for the former; the plan's unspecified "Bonsplit catalog validation" for the latter). If the new help string is composed *in Bonsplit*, it needs seven `.strings` entries; if composed in c11 and passed in as data (which the generic-seam principle favors), Bonsplit needs zero. The plan's arch item 4 implies the latter, but step 5 does not confirm it. Also: `String(localized:)` with a `defaultValue` containing interpolation must use a proper format string with plural rules, not Swift interpolation, or `2 minutes` / `1 minutes` ships in seven languages — the contract's "plural-safe" requirement is easy to miss and the existing `surface.flag.accessibility` key (`"Flagged: \(reason)"`) shows the interpolation-in-defaultValue style already in use here.

---

## Alternatives Considered

**Duration strings in the model vs. dates in the model.** Covered above; dates win decisively — Equatable stability, testability, and no clock coupling in the payload. No real argument for strings beyond one less function call.

**New transition-timestamp map vs. reuse `metadataSources` `ts`.** `SessionPanelSnapshot.metadataSources` already carries per-key `(source, ts)`, and if lifecycle transitions are reflected in metadata writes, that `ts` is a free state-start with persistence already solved. Tempting. But `setDerivedActivity` is driven by `SurfaceLivenessDeriver.onShellActivityChanged` (shell-activity heuristics), not by metadata writes, so the `ts` would only be right for agents that self-report — inconsistent by terminal type, which is worse than honest absence. A small in-memory `[UUID: Date]` beside `derivedActivityBySurface` is the better bet: authoritative for every surface, ~16 bytes each, and correctly forgotten on restart.

**Tooltip via `.help()` vs. AppKit `NSView.toolTip`.** `.help()` is one line, works today elsewhere in this codebase (14 call sites, including `SurfaceManifestView:358` for an *age* tooltip — near-identical prior art), and adds no hosting layer. Its cost is eagerness and accessibility entanglement with the combined element. An AppKit representable gives lazy, hover-time text and full control of the tooltip without touching accessibility, at the cost of a new view type inside bonsplit's most latency-sensitive view. **I'd take `.help()` with a sync-time string and a documented staleness bound** (the payload already re-syncs on lifecycle/attention transitions, and the contract permits "the existing coarse shared clock or an equally bounded leaf-only mechanism"), rather than introduce `onHover` into a view whose comments record a tap-breaking regression from exactly that. But this is a real fork with real tradeoffs and the plan should own it explicitly rather than leave the implementer to discover `.help()` is eager mid-flight.

**Extend `BonsplitTabActivityPresentation` vs. new parallel field on `Tab`.** Extending the existing struct is right: it is already the generic host-injection seam, already carries `accessibilityValue` for this exact purpose, and `Tab` is **not** `Codable` (verified), so there is no persistence-backcompat cost. One caution the plan omits: `BonsplitTabActivityPresentation` *is* `Codable`, so if anything ever persists it, a new non-optional field breaks decode — make it `String?` with a default, matching every existing field.

---

## Readiness Verdict

**Needs revision.** Do not start implementing from this text.

The plan becomes ready when it adds the following. All are small — I estimate the whole revision at 30-50 lines, not a rewrite:

1. **A stated source for every duration, including working.** Either add a transition-timestamp stamp in `setDerivedActivity` (recommended) or explicitly accept a bare `Working` tooltip as the shipped behavior — but *say which*, and say whether it persists across restart.
2. **The churn boundary, in one sentence.** "`Date?`s cross into `WorkspacePulseAgent` / the Bonsplit presentation; localized strings are composed at the leaf." Plus: no formatted-string field may enter any type reachable from `TabItemView.==`.
3. **A step 0.** Base commit (rebase onto `main`), worktree confirmation, `git submodule update --init --recursive ghostty vendor/bonsplit`, GhosttyKit symlink, and clean scoped `git status`.
4. **The bonsplit `main` precondition in step 5,** with the `symbolic-ref` and `merge-base --is-ancestor` checks named. The submodule is detached right now.
5. **Step 4 rewritten to forbid local `xcodebuild test`,** matching the standing operator rule: author coverage, `build-for-testing` as a link check only, PR CI executes assertions.
6. **The tooltip mechanism chosen** (`.help()` with sync-time text vs. hover-time AppKit), with the `onHover`/mouse-down hazard acknowledged, and the intended accessibility composition against the existing `accessibilityValue` + `accessibilityHint` stated so criterion 8's test has a target.
7. **A decision on the collapsed/overflow mark** (`TabBarView.swift:1238`) and on the timezone treatment of the existing `Captured` row.

Nothing here changes the plan's architecture. Every fix is a sentence or two of specificity in a step that already exists — which is the good news: the plan's skeleton is sound, it is the load-bearing details that were compressed out.

---

## Questions for the Plan Author

1. **Where does working-state-start come from?** I could not find any lifecycle-transition timestamp in the codebase (`derivedActivityBySurface` is a bare enum, `coldAgentSurfaceIds` a bare `Set`, `SurfaceActivityTracker.lastActivity` overwritten continuously). Is the intent to (a) add a transition stamp, (b) ship bare `Working` with no duration, or (c) something I missed?
2. If (a): does adding a `[UUID: Date]` stamp beside `derivedActivityBySurface` count as "changing lifecycle inference" under step 1's fence, or is that explicitly permitted?
3. **Should working-state-start persist across restart?** `Working for 3 days` after a reboot seems clearly wrong, but step 3 persists only `createdAt` and the contract is silent.
4. **Does `WorkspacePulseAgent` receive `Date?`s or formatted strings?** Step 2's "precompute it for ... `WorkspacePulseAgent`" is ambiguous, and the string reading breaks `TabItemView`'s `.equatable()` on every minute boundary.
5. **What mechanism satisfies "refresh tooltip copy on hover entry"** given `.help(_:)` is eager? Leaf `@State` + `onHover` (hazardous per `TabBarView.swift:1034`), an AppKit `toolTip` representable, or a sync-time string with accepted staleness?
6. **What is the intended VoiceOver composition on the top tab?** The tab already exposes `accessibilityValue` (including C11-184's `Flagged: <reason>`) and `accessibilityHint` (`TabActivityAccessibility.help`), and is `children: .combine` with the mark `accessibilityHidden(true)`. Which channel carries lifecycle+duration+modifiers, and what gets removed to avoid the duplication the contract forbids?
7. **Does the collapsed/overflow tab-bar mark (`TabBarView.swift:1238`, `collapsedActivityMark`) get a tooltip?** It is neither the individual top-tab mark nor the c11 sidebar aggregate rail, so the contract doesn't resolve it.
8. **Does the existing `Captured` row gain a timezone?** Its formatter is `"yyyy-MM-dd HH:mm:ss"` with no zone, and the contract requires timezone on the new absolute timestamps. Two formats in one panel, or update `Captured` too?
9. **Who performs the `createdAt` / last-activity lookup for Surface Details?** `SurfaceManifestSnapshot.capture` takes only two UUIDs today and reads `SurfaceMetadataStore.shared`. Does it gain a `Workspace`/`TabManager` dependency, or does the caller inject a prebuilt facts value (better for testing criterion 5)?
10. **Is `createdAt` added to the `Panel` protocol** (public, `@MainActor`, three conformers) as a required property, or held per-implementation? "Promote optional logical `createdAt` through the `Panel` implementations" reads either way.
11. **Where does `createdAt` come from for surfaces restored from a legacy snapshot that are then long-lived?** Contract says show `Not recorded` — does the surface stay `Not recorded` forever, or get stamped at restore time (which would fabricate a creation time)? I read the contract as "forever `Not recorded`"; please confirm, since stamping-at-restore is the tempting shortcut.
12. **Is the new Bonsplit help field data-only** (c11 composes the localized string, Bonsplit just renders it), or does Bonsplit compose from parts? The former needs zero new `.lproj` entries; the latter needs seven. Step 5's "six-locale pass" suggests the former but doesn't say.
13. **What exactly is "Bonsplit catalog validation" in step 5?** For c11 the contract names `jq` plus interpolation-token checking; the Bonsplit `.lproj` equivalent is unspecified.
14. **Was the omission of the bonsplit `checkout main` / fast-forward precondition deliberate?** The submodule is detached in both the primary checkout and the C11-185 worktree right now, so step 5 as written orphans the commit.
15. **Does step 4's "Run focused safe logic/host tests" intend local `xcodebuild test`?** CLAUDE.md and prior operator interruption (C11-181) prohibit all local test actions in this repo, including `c11-logic`.
16. **Should the plan carry a base-commit gate?** The worktree is 2 commits behind `main`; C11-184's plan had an explicit ancestry gate and this one has none.
17. **How is criterion 5 ("agrees at the same clock instant") actually tested** if the tooltip string is built at sync time and Surface Details is built at capture time? Does the test inject a fixed `now` into one shared formatter — and if so, is the formatter's `now` a parameter rather than `Date()`?
18. **Plural safety:** will the duration strings use proper plural-variant format strings, or Swift interpolation inside `defaultValue` (the style used by the existing `surface.flag.accessibility` key)? The latter cannot express `1 minute` / `2 minutes` correctly across seven locales.
19. **Is a bulk read added to `SurfaceActivityTracker`?** Its point read is `queue.sync`; N per-agent reads per sidebar evaluation is a serialized hop per agent from the main thread onto a `.utility` queue.
20. **Is computer-use approval expected to actually land this time?** C11-184 shipped with both visual gates deferred because approval was withheld. Step 6 depends on it; if it is withheld again, does C11-185 ship unvalidated, or block?
