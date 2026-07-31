# Standard/Analytical Plan Review Synthesis — C11-185

- **Plan under review:** `.lattice/plans/task_01KYQYND86DZMKGR58BJ4Y3R53.md` (C11-185, agent-state tooltips + Surface Details activity timestamps)
- **Contract:** `.lattice/plans/c11-185-plan-review-pack-2026-07-29T1828/context-task-spec.md`
- **Reviews synthesized:** `standard-claude.md`, `standard-codex.md`, `standard-gemini.md`
- **Synthesized:** 2026-07-29

---

## Executive Summary

1. **The verdict is unanimous: Needs revision.** All three models independently landed on the same call, with the same qualifier: the architecture is right, the plan text is not executable. No model recommended rethinking the approach, and no model called it ready. That is an unusually clean 3/3 convergence and should be treated as settled.

2. **All three models diagnosed the same root failure: the plan restates the contract instead of designing against it.** Claude: "a table of contents for a plan rather than the plan." Codex: "the right feature architecture expressed as a good six-line outline." Gemini: "essentially a regurgitation of the task specification." The plan names correct seams in a correct order and then defers every hard decision to the coding phase.

3. **All three converged on the same single most important gap: the temporal delivery mechanism.** The contract requires tooltip copy to refresh on hover entry and Surface Details relative values to stay current, while also requiring precomputed immutable payloads in parent/state-sync paths. The plan does not reconcile those. Every model flagged it; every model made it a blocking item.

4. **All three converged on the same fix for it: carry dates across the model boundary, format strings at the leaf.** This was reached independently three times from three angles (Equatable-churn risk, staleness-by-construction, and testability). It is the highest-confidence recommendation in the pack and should be written into the plan as an explicit one-sentence boundary rule.

5. **The most instructive disagreement is about *which* duration lacks a trustworthy source.** Claude says `Working` has no state-start timestamp anywhere in the codebase. Codex says the missing seam is an exact per-surface *waiting* timestamp in `TerminalNotificationStore`. Gemini says the unexplained one is *cold* threshold-crossing arithmetic. Three models, three different broken sources, zero overlap. The signal is not that any one of them is wrong: it is that **the duration-source table is the load-bearing artifact the plan omitted**, and its absence let each reviewer's attention land on a different hole.

6. **The sharpest direct contradiction is on `WorkspacePulseAgent` precomputation.** Claude rates it a high-severity fleet-wide typing-latency regression (formatted duration strings inside an `Equatable` payload compared by `TabItemView.==`). Codex lists the same step as a **strength** ("performance-aware projection"). Both readings are defensible against the plan's actual words, which is precisely the problem: the plan does not distinguish "precompute the projection" from "precompute the string," and the dangerous reading is the shorter one.

7. **Verification depth differs materially and should weight your reading.** Claude and Codex both cite specific files and line numbers and report state they checked in the working tree. Gemini reviewed at the document level only, with no code citations. Gemini's findings are still useful (it surfaced the cold-arithmetic gap nobody else did, and it alone framed the hover/precompute tension as a possible *contract* contradiction rather than a plan omission), but where Gemini and a code-citing model disagree, prefer the citation.

8. **Revision scope is small and agreed.** Claude estimates 30 to 50 lines. Codex calls the amendments "bounded" with architecture and scope unchanged. Gemini asks only for the "how" on the trickiest parts. Nobody is asking for a rewrite.

---

## 1. Where the Models Agree (Highest Confidence)

Ranked by strength of agreement and by cost of ignoring.

### 1.1 Unanimous, blocking

1. **Verdict: Needs revision, not rethinking.** 3/3. The decomposition, the ordering instinct, and the scope fences are sound; the details were compressed out.

2. **The hover-refresh / tooltip-freshness mechanism is unspecified and must be chosen in the plan.** 3/3, all as a blocking item. A preformatted string is stale by construction; the contract demands freshness; the plan picks neither a mechanism nor an accepted staleness bound.

3. **The projection payload must carry timestamps and semantic facts, not preformatted localized strings.** 3/3. Claude frames it as Equatable stability plus testability; Codex as staleness plus fixed-clock provability; Gemini as the unanswered data-structure question. Recommended plan language: *dates cross the model boundary, localized strings are composed at the leaf, and no formatted-string field may enter any type reachable from `TabItemView.==`.*

4. **The plan is too shallow to hand to a fresh agent in an isolated worktree.** 3/3. All three note that the intended reader has no memory of the C11-183/184 runs and needs to know where the numbers come from, not just which files to touch.

### 1.2 Unanimous, praised (do not revise these away)

5. **One shared projection consumed by all tooltip locations plus Surface Details.** 3/3 named this the plan's strongest call. It makes the cross-surface agreement criterion a property of one pure value rather than a convention among three renderers, and it makes the hardest assertion a pure, fixed-clock one.

6. **Refusing to launder derived UI facts through `SurfaceMetadataStore`.** 3/3. Keeps a display concern from becoming permanent agent-visible API surface with false persistence and precedence semantics.

7. **Honest missing evidence over fabrication.** 3/3. Legacy snapshots stay nil, `Not recorded` is shown, `0 minutes` is never invented.

8. **Scope fence against reopening C11-183/184 lifecycle inference.** 3/3 treated this as correctly avoiding the most dangerous scope expansion. (See divergence 2.4 for the one place the fence is read as too tight.)

### 1.3 Two-of-three, high confidence

9. **`Panel.createdAt` plus `SessionPanelSnapshot` is the correct persistence boundary.** Claude and Codex both affirm; both reject the alternatives (workspace-side dictionary keyed by panel ID, terminal-runtime debug timestamp, metadata, capture time, app-launch time). Codex adds the precedent: `SessionPanelSnapshot` already carries an optional `lastActivityAt`, so the backward-compatible pattern exists in-repo.

10. **The Surface Details capture seam cannot deliver the promised truth as written.** Claude and Codex both verified `SurfaceManifestSnapshot.capture(workspaceId:surfaceId:)` takes only two UUIDs and reads `SurfaceMetadataStore.shared`. It can see neither panel creation time nor the already-projected lifecycle. Both demand a named provider or injected facts value, and Codex adds that Refresh must rerun that same provider.

11. **The absolute timestamp formatter has no timezone.** Claude and Codex both cite `SurfaceManifestView.timestampFormatter` as `"yyyy-MM-dd HH:mm:ss"`, against a contract that requires timezone-bearing absolute values. Reusing the existing formatter silently fails the criterion.

12. **Accessibility composition will duplicate lifecycle unless override semantics are defined.** Claude and Codex both flag it, from different ends: Claude from the c11 side (the tab is already `children: .combine` with an `accessibilityValue` and an `accessibilityHint`, and the mark is `accessibilityHidden(true)`), Codex from the Bonsplit side (Bonsplit appends the host `accessibilityValue` and then its own lifecycle label). Same conclusion: state the intended final composition so the acceptance test has a target.

13. **A step 0 is missing: base ancestry, worktree confirmation, submodule and framework provisioning, clean scoped status.** Claude and Codex both call for it. Claude adds the live risk: the primary checkout carries roughly 206 uncommitted operator lines in `Sources/ContentView.swift`, a file this ticket must edit.

14. **Computer-use approval scope should be recorded in the plan, not just requested.** Claude and Codex both raise it. Claude adds the precedent that C11-184 shipped with both visual gates deferred because approval was withheld.

---

## 2. Where the Models Diverge (The Disagreement Is Signal)

### 2.1 Which duration has no trustworthy source — three different answers

| Model | Claimed missing source | Evidence offered |
|---|---|---|
| Claude | **Working.** No lifecycle-transition timestamp exists anywhere. `derivedActivityBySurface` is a bare enum map; `coldAgentSurfaceIds` is a bare `Set<UUID>`; `SurfaceActivityTracker.lastActivity` is overwritten on every input so `now - lastActivity ≈ 0` while working. | Line-level citations, plus a four-state availability table (idle yes, cold yes, waiting yes, working no). |
| Codex | **Waiting.** `TerminalNotificationStore.NotificationIndexes` exposes exact-surface unread *membership* but not that notification's `createdAt`; only workspace-level latest unread is retained. Working/idle are treated as available from the c11-observed lifecycle or input boundary. | Line-level citations to `TerminalNotificationStore.swift`. |
| Gemini | **Cold.** The plan tests threshold arithmetic but never says how the projection computes time-since-crossing rather than total idle time. | None (document-level read). |

**Reading of the disagreement.** These are not mutually exclusive; they are three holes in the same missing artifact. Claude's is the most severe if correct, because an implementer can ship a bare `Working` tooltip and technically pass the acceptance criterion while gutting the ticket's headline example. Codex's is the most concrete seam to add. Gemini's is the cheapest to get wrong silently, since falling back to total idle time produces a plausible-looking number that is simply the wrong quantity.

**Action:** the plan must carry an explicit **state-to-timestamp-source table** covering working, idle, cold, waiting, and suppressed-waiting, with a named accessor for each, and an explicit decision where no source exists today. All three reviews collapse into this one artifact.

### 2.2 Is `WorkspacePulseAgent` precomputation a strength or a regression?

- **Claude: high-severity regression.** `TabItemView.==` compares `lhs.workspacePulse == rhs.workspacePulse`; `WorkspacePulseSummary` holds `agents: [WorkspacePulseAgent]`; the call site depends on `.equatable()` to skip body re-evaluation during typing. A ticking duration string inside `WorkspacePulseAgent` flips equality on every minute boundary for every workspace row with an agent, defeating the documented typing-latency defense fleet-wide. Claude also names the trap's shape: it satisfies the *letter* of the guardrail ("precompute immutable payloads in the existing parent/state-sync paths") while violating its *intent*.
- **Codex: strength.** Lists "performance-aware projection: precomputing immutable evidence for `WorkspacePulseAgent` and the top-tab sync path is consistent with c11's typing-hot constraints."
- **Gemini: unresolved ambiguity.** Flags that the plan does not explain how precompute and hover-refresh coexist, without adjudicating.

**Reading.** The contradiction is downstream of the plan's ambiguity, not of a factual dispute. Codex says "immutable *evidence*" (dates), Claude is warning about immutable *text* (strings). Both are right under their own reading, and the plan permits both readings. This is the single clearest demonstration that agreement item 1.1.3 (dates cross, strings stay at the leaf) is load-bearing: writing that sentence makes Claude's regression structurally impossible and confirms Codex's strength.

### 2.3 What mechanism should satisfy hover-time freshness?

- **Claude: `.help()` with a sync-time string and a documented staleness bound.** Argues `.help(_:)` is eager with no lazy variant, and that the alternative (leaf `@State` + `onHover` inside the tab) is the documented way to break tab selection: `TabBarView.swift:1034` carries an in-repo warning that a child `.onHover` creates an AppKit hosting layer that swallows mouse-down, "that mistake is why the tap broke once." Effectively proposes relaxing the contract's hover-entry requirement to a bounded-staleness requirement.
- **Codex: a leaf-only refresh that actually is current.** Points at `SidebarDecayClock`, an existing shared 30-second leaf clock that already forbids observation from `TabItemView`, as the candidate, or an equally bounded hover-local nonrepeating mechanism. Wants the contract satisfied, not relaxed.
- **Gemini: an `ObservableObject` or localized state wrapper attached to the tooltip modifier**, computing the string on demand when hover state changes, reading from the immutable baseline timestamp payload. Closest to the mechanism Claude explicitly warns against.

**Reading.** This is a genuine three-way fork with real tradeoffs, and it is the plan's central unforced decision. Claude's hazard citation is specific and in-repo, so Gemini's proposal should not be adopted without addressing it. Codex's `SidebarDecayClock` reuse is the most promising synthesis: it gives freshness without an `onHover` hosting layer and without per-agent timers, and it is already architecturally fenced away from `TabItemView`. Note the two models also disagree about whether "refresh on hover entry" is a hard contract requirement or a bounded-staleness requirement in disguise; that question should go back to the contract author.

### 2.4 Is the "without changing lifecycle inference" fence too tight?

- **Claude: yes, resolve the ambiguity in the plan.** Argues that stamping a transition time beside `setDerivedActivity` (whose own comment advertises it as "cheap and I/O-free," an ideal stamping site) changes no inferred state and should be explicitly permitted, or a cautious implementer will read step 1 as forbidding the one change the feature needs.
- **Codex: implicitly no.** Explicitly declines to add "a new generalized temporal event history subsystem, per-surface timers, or persisted lifecycle-transition log," on the grounds that more infrastructure enlarges the truth claims and conflicts with the out-of-scope list.
- **Gemini: silent.**

**Reading.** Less opposed than it first appears. Claude proposes a small in-memory `[UUID: Date]` map, deliberately non-persisted (arguing "Working for 3 days" across a reboot is a lie). Codex rejects a *persisted* transition log and a general subsystem. Those are compatible. But the plan currently authorizes neither, so the decision must be made in text.

### 2.5 Is the step ordering adequate?

- **Claude: yes.** "Six steps map to baseline, pure projection, persistence, tests, submodule/localization, validation. I would arrive at the same shape." Its only structural complaint is that step 3 conflates a mechanical `createdAt` refactor with an unanswered capture-seam design question, and should split.
- **Codex: no, reorder.** Proposes a seven-step sequence that locks pure semantics and fixed-clock tests *before* renderer wiring, so semantic errors fail before submodule and UI work. Separately flags a real ordering bug: step 5 pushes the parent branch and Bonsplit main *before* step 6 self-review, with no correction-and-reverification loop after the last fix.
- **Gemini: silent on ordering.**

**Reading.** Codex's step-5-before-step-6 catch is a concrete defect and should be fixed regardless of whether the broader reorder is adopted. The tests-before-renderers reorder is a preference call; Claude's split-step-3 suggestion achieves much of the same benefit at lower churn.

### 2.6 Local test execution

- **Claude: step 4's "run focused safe logic/host tests and build checks" is the most dangerous line in the plan.** CLAUDE.md and operator memory both record local `xcodebuild test` as prohibited in this repo during delegator runs, *including* the nominally-safe `c11-logic` scheme, after an operator interruption on C11-181. Recommends: author coverage, use `build-for-testing` as a link check only, let PR CI execute assertions.
- **Codex: no objection**, and its own proposed decomposition includes "run scoped tests/builds."
- **Gemini: silent.**

**Reading.** Claude is correct on repo policy and this is not a matter of taste. Adopt Claude's rewrite. Codex's phrasing would reproduce the interruption.

### 2.7 Submodule state

- **Claude: high severity, and live right now.** Verified `vendor/bonsplit` is on a **detached HEAD** in both the primary checkout and the C11-185 worktree. Step 5 says push to bonsplit `main` before the parent pointer but never says *check out `main` first*, so an implementer following it verbatim commits on detached HEAD, pushes nothing, and orphans the commit. C11-184's plan gated this in Phase 0 and logged it as a review resolution; C11-185 dropped it.
- **Codex: generic.** Asks for a "submodule-state gate" without naming the precondition or the current state.
- **Gemini: silent.**

**Reading.** Claude's verified working-tree state upgrades this from hygiene to an active landmine. Adopt the concrete checks.

---

## 3. Unique Insights (Single-Model Findings)

### 3.1 Claude only

1. **`Working` has no state-start source anywhere**, with a per-state availability table and the downstream failure mode spelled out (an implementer ships bare `Working`, passes the letter of criterion 2, and the ticket's own headline example never renders).
2. **The `Equatable` hot-path churn mechanism, with line numbers** (`TabItemView.==` at `ContentView.swift:11736-11756`, `.equatable()` at the call site, `WorkspacePulseProjector.project` running inline in the sidebar `ForEach`).
3. **`vendor/bonsplit` is detached HEAD in both checkouts right now.**
4. **`.help(_:)` is eager with no lazy variant**, and `TabBarView.swift:1034` documents that a child `.onHover` in the tab swallows mouse-down. This pairing is what makes the mechanism choice non-free.
5. **`SurfaceActivityTracker.lastActivity` is a `queue.sync` read** onto a serial `.utility` queue. N per-agent point reads per sidebar evaluation is a serialized hop per agent from the main thread, with priority-inversion risk. Recommends one bulk snapshot per sync, mirroring the existing `seed(from:)`.
6. **The padded hit area the contract asks for already exists**: the mark sits in a fixed-size `HStack` with `Color.clear` pads and an explicit `.frame(width: leadingAccessoryWidth, height: tabItemHeight)`. A `.help()` on that container needs no geometry change, which makes the "tab selection unchanged" criterion nearly free. Worth naming because it converts a feared risk into a non-issue.
7. **Near-identical prior art exists**: `SurfaceManifestView:358` already uses `.help()` for an age tooltip, one of 14 `.help()` call sites in the codebase.
8. **A third mark call site is undecided**: `TabBarView.swift:1238` `collapsedActivityMark`, the collapsed/overflow control chip. It represents the active tab plus background-waiting, so it is neither clearly individual nor clearly aggregate, and neither the contract nor the plan resolves it. C11-184's plan remembered to say "and any alternate/compact tab-bar mark call sites."
9. **Localization scope is understated: seven catalogs, not six.** `vendor/bonsplit/Sources/Bonsplit/Resources/` has seven `.lproj` directories, and there are two catalog systems with different formats and different validators (`jq` for c11's `.xcstrings`, unspecified for Bonsplit's `.lproj`). If the help string is composed in c11 and passed as data, Bonsplit needs zero new entries; if composed in Bonsplit, it needs seven.
10. **Plural safety is a seven-language crash-or-embarrassment risk.** `String(localized:)` with interpolation inside `defaultValue` (the style the existing `surface.flag.accessibility` key already uses) cannot express `1 minute` versus `2 minutes` correctly. Proper plural-variant format strings are required.
11. **`BonsplitTabActivityPresentation` is `Codable`**, so any new field must be optional with a default, matching every existing field. (`Tab` itself is verified *not* `Codable`, so there is no persistence back-compat cost there.)
12. **A rejected alternative worth recording:** reuse `SessionPanelSnapshot.metadataSources`'s per-key `ts` as a free, already-persisted state-start. Rejected because `setDerivedActivity` is driven by `SurfaceLivenessDeriver.onShellActivityChanged` (shell heuristics), not by metadata writes, so the `ts` would only be correct for self-reporting agents. Inconsistent by terminal type is worse than honest absence.
13. **The stronger reframing:** define one `SurfaceActivityFacts` value type (four optional `Date`s plus modifier facts) with two renderers. Under that framing the Equatable risk vanishes by construction, the four "where does this date come from" questions surface in the first five minutes, formatting becomes one pure `(facts, now, locale) -> String`, and Surface Details needs no new plumbing beyond the same value.
14. **Environment facts:** the worktree is 2 commits behind `main`, and the primary checkout has roughly 206 uncommitted operator lines in `Sources/ContentView.swift`.
15. **The `Captured` row consistency question:** the contract says it "remains separate," but does it now also gain a timezone (consistent, but a visible change to an untouched row), or do two timestamp formats coexist in one panel?

### 3.2 Codex only

16. **`TerminalNotificationStore` lacks an exact per-surface notification timestamp.** Indexes carry `(workspace, surface)` unread membership plus workspace-level latest unread, but not the surface notification's `createdAt`. Waiting duration needs a bounded signal-eligible per-surface accessor or index. Notes that `addNotification` replaces the prior record for the same surface, but warns the plan must not rely on scanning the published notification array from a view.
17. **The double-announcement mechanism on the Bonsplit side:** Bonsplit appends the host `accessibilityValue` and then its own lifecycle label, so supplying a complete lifecycle-duration-modifier phrase through the current field announces state twice. Requires defining override versus fallback semantics, with a host-supplied complete phrase *replacing* rather than preceding Bonsplit's fallback, while Loading, Pinned, Unread, Modified, and Zoomed still compose once.
18. **`SidebarDecayClock` already exists** as a shared 30-second leaf clock that explicitly forbids observation from `TabItemView`. The plan should say whether it is reused or a hover-local nonrepeating mechanism is used instead.
19. **`SessionPanelSnapshot.lastActivityAt` is the in-repo precedent** for a backward-compatible optional snapshot field.
20. **Suppressed-waiting is a semantic trap.** For a raw-waiting surface suppressed and therefore presented as idle, does the displayed idle duration use `SurfaceActivityTracker.lastActivity` or the unread notification's creation time? Generalizes to: does the payload distinguish raw from presented lifecycle, and which is authoritative for state-start selection?
21. **"Optional `createdAt`" must not let fresh surfaces be nil.** Fresh terminal/browser/markdown constructors should default to call-time `Date()`; restore should pass snapshot `createdAt` verbatim, including explicit nil.
22. **The creation-path audit is wider than three methods.** Split creation, placeholders and repair, layout restore, CLI/socket creation, and direct panel construction must either route through the same initializer defaults or be listed as covered.
23. **Static screenshots cannot validate a temporal feature.** Validation should include at least one hover or details-age observation across a minute boundary, plus visible missing-evidence and legacy-restored cases.
24. **Review/fix ordering defect:** step 5 pushes the parent branch and Bonsplit main before step 6 self-review, with no correction-and-reverification loop and no final scoped status/ancestry check after the last fix.
25. **Do not silently broaden observation claims.** Browser and markdown Surface Details will likely show `Last activity: Not recorded` until c11 has a trustworthy source for them; the plan should say so rather than imply coverage it does not have.
26. **The clipboard/copy path needs the same unambiguous timezone-bearing format** as the displayed value.
27. **Explicit anti-scope:** no generalized temporal event-history subsystem, no per-surface timers, no persisted lifecycle-transition log. The ticket needs only the latest trustworthy boundaries plus logical creation time.

### 3.3 Gemini only

28. **Cold-duration arithmetic is untreated.** The contract specifies that cold begins when last activity plus `SidebarAgentColdSettings.thresholdSeconds()` is crossed. The plan says it will *test* this but never says how the projection computes time-since-crossing instead of falling back to total idle time. The failure mode is quiet: a plausible number that is the wrong quantity.
29. **The tension may live in the contract, not only the plan.** Gemini alone reads "refresh tooltip copy on hover entry" and "precompute immutable payloads in the existing parent/state-sync paths" as *seemingly conflicting requirements* and faults the plan for not reconciling them. The other two treat the gap purely as a plan omission. If the contract is genuinely self-conflicting, that is a question for the contract author, not a design task for the implementer.
30. **The named meta-risk: intent drift.** Because the plan restates the spec rather than designing, the implementing agent invents the architecture on the fly, which is where drift enters. This is the cleanest articulation in the pack of *why* superficiality is a defect and not merely a style preference.
31. **A mechanical enumeration ask** the others left abstract: which specific `Panel` classes and which session snapshot decoders need modification to plumb the optional `createdAt`.

---

## 4. Consolidated Questions for the Plan Author

Deduplicated across all three reviews and grouped. Attribution in brackets: C = Claude, X = Codex, G = Gemini.

### A. The temporal payload and its data sources (the blocking cluster)

1. Is the shared activity-help projection a **timestamp-bearing semantic payload** with a pure `text(at:)` formatter, or a **preformatted localized string**? If the latter, how is hover-time freshness satisfied? [C, X, G]
2. What is the exact **state-to-timestamp-source table** for working, idle, cold, waiting, and suppressed-waiting? Name the accessor for each. [C, X, G]
3. **Where does working-state-start come from?** No lifecycle-transition timestamp appears to exist (`derivedActivityBySurface` is a bare enum map, `coldAgentSurfaceIds` a bare `Set`, `SurfaceActivityTracker.lastActivity` continuously overwritten). Intent: (a) add a transition stamp, (b) ship bare `Working` with no duration, or (c) a source the reviewers missed? [C]
4. If (a): does adding a `[UUID: Date]` stamp beside `derivedActivityBySurface` count as "changing lifecycle inference" under step 1's fence, or is it explicitly permitted? [C]
5. Should working-state-start **persist across restart**? "Working for 3 days" after a reboot is a lie, but the contract is silent and step 3 persists only `createdAt`. [C]
6. Will `TerminalNotificationStore.NotificationIndexes` gain a **signal-eligible timestamp keyed by `(workspaceId, surfaceId)`**, and is the intended waiting start the creation time of the one current replacement notification? [X]
7. For a **raw-waiting surface that is suppressed and presented as idle**, does the displayed idle duration use `SurfaceActivityTracker.lastActivity` or the unread notification's creation time? [X]
8. Does the payload **distinguish raw from presented lifecycle**, and which is authoritative for state-start selection? This matters for suppressed waiting and for flag-plus-suppression. [X]
9. How is **cold duration** computed so it reflects time since `lastActivity + thresholdSeconds()` was crossed, rather than total idle time? [G]

### B. Freshness mechanism and hot-path safety

10. What exact mechanism refreshes the tooltip **without** observing a repeating timer in the `Equatable` tab body, **without** per-agent timers, and **without** teaching Bonsplit c11 semantics? [C, X, G]
11. Is `SidebarDecayClock` (the existing shared 30-second leaf clock that already forbids observation from `TabItemView`) reused, or is a hover-local nonrepeating mechanism introduced? [X]
12. Given that `.help(_:)` takes its `String` **eagerly at body-build time** and has no lazy variant, and that `TabBarView.swift:1034` documents a child `.onHover` swallowing mouse-down (the recorded cause of a past tap regression), which of these is chosen: leaf `@State` + `onHover`, an AppKit `NSView.toolTip` representable, or a sync-time string with an accepted staleness bound? [C]
13. Does `WorkspacePulseAgent` receive **`Date?`s or formatted strings**? The string reading flips `TabItemView.==` on every minute boundary for every workspace row with an agent. [C]
14. Are the contract's "refresh on hover entry" and "precompute immutable payloads in the existing parent/state-sync paths" reconcilable as written, or does one of them need amending? [G]
15. Is a **bulk read** added to `SurfaceActivityTracker`? Its point read is `queue.sync`, so N per-agent reads per sidebar evaluation is a serialized main-thread hop per agent onto a `.utility` queue. [C]

### C. Surface Details capture seam

16. **Which provider or call path** supplies `SurfaceManifestSnapshot.capture` with the live panel's `createdAt` and the same activity payload the marks use? It takes only two UUIDs today and reads `SurfaceMetadataStore.shared`. Does it gain a `Workspace`/`TabManager` dependency, or does the caller inject a prebuilt facts value (better for testing the agreement criterion)? [C, X]
17. Does **Refresh** rerun that same provider, and which values are relative-and-live versus absolute-and-frozen-until-Refresh? [X]
18. Which clock owns relative updates while Surface Details is open? [X]
19. What exact **display and clipboard format** provides timezone-bearing, unambiguous absolute `Created` / `Last activity` values? [C, X]
20. Does the existing **`Captured` row gain a timezone**? Its formatter is `"yyyy-MM-dd HH:mm:ss"` with no zone. Two formats in one panel, or update `Captured` too? [C]
21. Will browser and markdown Surface Details normally show `Last activity: Not recorded`, or are there existing browser/markdown boundaries the implementation intends to adopt? [X]

### D. `createdAt` persistence

22. Is `createdAt` added to the **`Panel` protocol** (public, `@MainActor`, three conformers) as a required property, or held per-implementation? [C]
23. How does **fresh creation pass a nonnil call-time date while legacy restore preserves explicit nil** through the same constructors? "Optional" must not let fresh surfaces be nil. [X]
24. Which **creation paths beyond the three `new*Surface` methods** are in scope: split creation, placeholders and repair, layout restore, CLI/socket creation, direct panel construction? [X]
25. Which specific `Panel` classes and which session snapshot decoders are modified? [G]
26. For a surface restored from a **legacy snapshot** that then lives a long time: does it stay `Not recorded` forever, or get stamped at restore time (which fabricates a creation time)? The reviewers read the contract as "forever `Not recorded`"; please confirm, since stamping-at-restore is the tempting shortcut. [C]

### E. Bonsplit boundary, accessibility, and localization

27. What is the **intended final VoiceOver composition** on the top tab? The tab already exposes `accessibilityValue` (including C11-184's `Flagged: <reason>`) and `accessibilityHint`, is `children: .combine`, and has the mark `accessibilityHidden(true)`; Bonsplit separately appends the host value and then its own lifecycle label. Which channel carries lifecycle plus duration plus modifiers, and what is removed to avoid the duplication the contract forbids? [C, X]
28. Does a host-supplied complete phrase **replace** rather than precede Bonsplit's fallback lifecycle value, while Loading, Pinned, Unread, Modified, and Zoomed still compose once? [X]
29. Is the new Bonsplit help field **data-only** (c11 composes the localized string, Bonsplit only renders it), or does Bonsplit compose from parts? The former needs zero new `.lproj` entries; the latter needs seven. [C]
30. Does the **collapsed/overflow mark** (`TabBarView.swift:1238`, `collapsedActivityMark`) get a tooltip? It is neither the individual top-tab mark nor the c11 aggregate composition rail, so the contract does not resolve it. [C]
31. Localization is **seven catalogs, not six** (c11 `.xcstrings` plus Bonsplit's seven `.lproj`). What exactly is "Bonsplit catalog validation," given that `jq` plus interpolation-token checking covers only the c11 side? [C]
32. Will duration strings use **proper plural-variant format strings**, or Swift interpolation inside `defaultValue` (the style the existing `surface.flag.accessibility` key uses)? The latter cannot express `1 minute` versus `2 minutes` across seven locales. [C]
33. Any new field on `BonsplitTabActivityPresentation` must be **optional with a default**, since the struct is `Codable`. Confirmed? [C]

### F. Process, environment, and validation

34. Was the omission of the bonsplit **`checkout main` / fast-forward precondition** deliberate? `vendor/bonsplit` is detached in both the primary checkout and the C11-185 worktree right now, so step 5 as written orphans the commit. [C, X]
35. Does step 4's "run focused safe logic/host tests" intend **local `xcodebuild test`**? CLAUDE.md and a prior operator interruption (C11-181) prohibit all local test actions in this repo, including `c11-logic`. [C]
36. Should the plan carry a **base-commit and worktree gate** (step 0)? The worktree is 2 commits behind `main`, the primary checkout has roughly 206 uncommitted lines in a file this ticket edits, and C11-184's plan had an explicit ancestry gate. [C, X]
37. What is the **correction loop after step 6 self-review**, given that step 5 already pushed the parent branch and Bonsplit main? Where is the final scoped status and ancestry check after the last fix? [X]
38. How is the **cross-surface agreement criterion actually tested** if the tooltip string is built at sync time and Surface Details at capture time? Does the test inject a fixed `now` into one shared formatter, and is that `now` a parameter rather than `Date()`? [C]
39. Will tagged QA include a **duration-boundary refresh observation** across a minute boundary, plus a visible legacy/missing-evidence case, rather than static screenshots only? [C, X]
40. Has the **scoped computer-use approval** been recorded with the tagged app, exact hover and right-click flows, screenshot destinations, and data limits, so a fresh validator can rely on it? And if approval is withheld again as it was on C11-184, does C11-185 ship unvalidated or block? [C, X]

---

## 5. Synthesized Readiness Verdict

### 5.1 The call

**Needs revision. Do not begin implementing from the current plan text.**

Unanimous across all three models, with identical qualification: the architecture is right, the scope is right, the ordering is close, and the omissions are load-bearing details rather than structural faults. Nobody asked for a rewrite. Claude sizes the revision at 30 to 50 lines; Codex calls the amendments "bounded" with architecture and scope unchanged; Gemini asks only for the "how" on the trickiest parts.

### 5.2 The convergent revision set (do all of these)

1. **Write the churn boundary in one sentence.** Dates cross the model boundary into `WorkspacePulseAgent` and the Bonsplit presentation; localized strings are composed at the leaf; no formatted-string field may enter any type reachable from `TabItemView.==`. [3/3, and this single sentence resolves divergence 2.2 outright]
2. **Add the state-to-timestamp-source table** covering working, idle, cold, waiting, and suppressed-waiting, with a named accessor for each and an explicit decision wherever no source exists today. [3/3, and it is the artifact whose absence produced divergence 2.1]
3. **Choose the freshness mechanism explicitly** and record the `.help()` eagerness and `onHover` mouse-down hazards as considered-and-addressed. [3/3]
4. **Name the Surface Details capture provider** and state that Refresh reruns it. [2/3]
5. **Add the missing truth-acquisition seams**: an exact per-surface signal-eligible waiting timestamp accessor, and whatever working-state-start decision is made in item 2. [Codex + Claude respectively]
6. **State the intended accessibility composition** and the override-versus-fallback rule against Bonsplit's own lifecycle label, so the acceptance test has a target. [2/3]
7. **Add a step 0**: base ancestry and rebase, worktree confirmation, `git submodule update --init --recursive ghostty vendor/bonsplit`, GhosttyKit symlink, clean scoped `git status`. [2/3]
8. **Add the bonsplit `main` precondition to step 5**, with `symbolic-ref --short HEAD == main` and `merge-base --is-ancestor HEAD origin/main` named. The submodule is detached right now. [2/3, with verified live state]
9. **Rewrite step 4 to forbid local `xcodebuild test`**: author coverage, `build-for-testing` as a link check only, PR CI executes assertions. [Claude, and correct on repo policy]
10. **Add the correction-and-reverification loop after self-review**, since step 5 pushes before step 6 reviews. [Codex]
11. **Add the timezone treatment**, including the decision on the existing `Captured` row and on the clipboard format. [2/3]
12. **Decide the collapsed/overflow mark, the seven-catalog localization scope, and plural safety.** [Claude]
13. **Make validation temporal**: at least one observation across a minute boundary, plus visible missing-evidence and legacy-restored cases, and record the approval scope. [2/3]

### 5.3 Two decisions that need the contract author, not the plan author

1. **Is "refresh tooltip copy on hover entry" a hard requirement, or a bounded-staleness requirement?** Claude's recommended mechanism relaxes it; Codex's insists on it; Gemini reads it as in tension with the precompute guardrail in the same contract. The plan cannot resolve this unilaterally without either accepting a hazard or missing a criterion.
2. **If `Working` genuinely has no state-start source, is a bare `Working` tooltip an acceptable ship?** It passes the acceptance criterion as written while removing the ticket's headline example. That is a product call, not an implementation call.

### 5.4 Confidence weighting for the reader

- **Claude** did the deepest working-tree verification (line-cited claims, live submodule and dirty-checkout state, availability audit per state) and carried the most institutional memory from the C11-183/184 runs. Its unique findings are the highest-yield section of the pack.
- **Codex** did the strongest boundary and seam analysis (notification store, Bonsplit accessibility composition, capture provider, creation-path audit) and was alone in catching the push-before-review ordering defect. It is also the only model whose stated strength list contains an item another model rates as a high-severity regression, so read item 1.6 of its strengths against divergence 2.2.
- **Gemini** reviewed at the document level with no code citations, and its findings are correspondingly less specific. It nonetheless surfaced two things neither other model did: the cold-arithmetic gap, and the possibility that the tension lives in the contract rather than the plan. Do not discard it; do prefer a code-citing model where they conflict.
