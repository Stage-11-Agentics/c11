# Adversarial Review Synthesis: C11-184 (flagged and suppressed agents)

- **Plan ID:** `c11-184-plan`
- **Plan under review:** `.lattice/plans/task_01KYMTXQVWCXCF0TGN5ZWG341E.md`
- **Reviews synthesized:** `adversarial-claude.md`, `adversarial-codex.md`, `adversarial-gemini.md`
- **Timestamp:** 20260728-1726

---

## Executive Summary

Three independent adversarial reviews converge on a single verdict: **the plan is not ready to implement, and the reason is not sloppiness, it is that several load-bearing contracts are unresolved or mutually contradictory.** All three reviewers praise the plan's rigor. All three conclude that the rigor is concentrated in the wrong places: threading discipline, commit grouping, color values, and evidence capture are meticulous, while state projection, actor provenance, persistence durability, lifecycle termination, and the executable test path remain unsettled.

The five highest-confidence findings, each flagged by two or three models:

1. **The suppressed-plus-flagged notification question is unresolved and it is the feature's headline case.** The binding spec, the task description, and the staged skill all say suppressed surfaces deliver no system notification. The plan requires suppressed flag raises to deliver one. Until every binding document is amended, the marquee use case ("do not tell me when you finish, do tell me if you get stuck") either contradicts the contract or reaches an absent operator through no channel at all. Claude additionally notes mark motion is gated on `scenePhase == .active`, so the in-app alarm flash stops precisely when the operator has switched away.

2. **The hard latency gate has no instrument.** A numeric pre-merge ship blocker (p95 delta <= 1 ms at 20-agent scale) is declared, and zero work is allocated to building the harness that would produce the number. No harness exists in `scripts/` or `tests_v2/`. The only existing instrument is DEBUG-only and threshold-truncated. Two of three reviewers call this the softest thing in the document, dressed as the hardest.

3. **One eligibility bit cannot serve every consumer.** The `!(suppressed && !flagged)` formula is the plan's central abstraction, and it collapses distinctions that consumers genuinely need: raw history, exact lifecycle unread, and routine waiting demand. The concrete symptom both Claude and Codex derive independently is a flagged-plus-waiting surface double-counted in the Flagged and Waiting rows, which is exactly the outcome the spec forbids and the review gate claims to prevent.

4. **Flags and suppression have no lifecycle end, and the system's correctness depends on discipline it does not enforce.** No expiry, no auto-lower, no bulk clear, no rate limit, no process-death coupling, no bulk read for suppression. All three models predict the same decay: flags rot, the Flagged Agents row becomes permanently non-zero, its "zero flags, zero footprint" design property is destroyed, and the feature degrades back into the flat waiting tier it was built to escape.

5. **Attribution (`by: operator | agent`) is not trustworthy and does not do what the spec says it does.** It is a caller-settable string on an unauthenticated same-user socket. Separately, Codex observes that even if it were trustworthy, a stopped agent is not subscribed to the event stream, so operator dismissal never reaches the blocked agent that the field exists to inform.

Beyond consensus, each model contributes at least one finding the others missed entirely and that is independently sufficient to change the plan: **Claude** finds a color-blindness gap in the mark renderers that sits inside a feature whose prerequisite was justified as an accessibility repair. **Codex** finds a ticket-identity collision (`C11-184` is already spent on merged PR #360) and a persistence gap (in-memory store plus 8-second autosave means an OK response is not crash-durable). **Gemini** finds the zombie-flag case (a flag on a surface whose PTY process has exited stays up forever) and the notification-center spam vector.

**Recommended next move, on which two models agree explicitly and the third implies:** a short architecture revision, not coding. Specifically: resolve the notification-policy question and amend all binding documents; replace one eligibility bit with an explicit projection set plus a consumer migration table; write down the operation-mode table for the attention service; name or build the latency instrument; and decide whether this ships as one PR or two.

---

## 1. Consensus Risks

Ordered by strength of agreement, then by severity. Model attribution in brackets.

### 1.1 The suppression / notification contradiction is unresolved in the binding contract [Claude, Codex, Gemini]

- The binding spec (`docs/c11-flagged-agent-plan.md:34-42, 257-263`), the task description, and the staged skill (`docs/c11-attention-model-skill-section.md:51-53`) all say suppressed surfaces deliver no system notification. The plan requires direct delivery on a suppressed flag raise (`task_...md:475-483`). [Codex]
- If the answer is "no delivery," the flagged-plus-suppressed combination, which the binding spec itself calls the most valuable one in the feature, has no out-of-app channel. The violet mark, the sidebar row, and the banner all reach an operator who is asleep or in another app. [Claude]
- Compounding it: mark motion is gated on `scenePhase == .active` (`WorkspaceContentView.swift:226`), so the alarm flash, described as the strongest visual signal c11 has, stops when the operator switches applications. That interaction appears nowhere in the plan. [Claude]
- The inverse framing: a suppressed agent that dies without raising a flag is a silent failure with no prompt to check on it. [Gemini]
- Consensus judgment: this is not a Phase 3 policy branch. It is a spec amendment that must land before Phase 1, and it must land in all binding documents at once, not as a late PR amendment. [Claude, Codex]

### 1.2 The latency gate is unmeasurable as written [Claude, Codex]

- No harness in `scripts/`, none in `tests_v2/`. [Claude]
- The only instrument, `CmuxTypingTiming` (`Sources/AppDelegate.swift:104`), is `dlog`-based and therefore DEBUG-only, is threshold-gated at 6 ms event delay and 1 ms handler duration so it discards sub-threshold samples (p50 is arithmetically underivable from it), and measures event delay plus handler duration, not keystroke-to-paint. [Claude]
- No probe, clock, sampling window, trial count, warm-up, baseline randomization, output artifact, or subscriber-count debug seam is specified. [Codex]
- A 1 ms p95 delta is inside the noise floor of an unpinned macOS machine running twenty live agent processes emitting terminal output. [Claude]
- Predicted failure mode, stated identically by both: the gate is not failed, it is never run, and everyone remembers it as having passed.

### 1.3 One signal-eligibility bit cannot serve all consumers [Codex primary, Claude secondary]

- A flagged surface with an unread notification must simultaneously preserve raw history, expose true `waiting` so the flagged-waiting alarm renders, remain flag-priority eligible, and not count as both a Flagged and a Waiting Agent. `!(suppressed && !flagged)` cannot satisfy that set. [Codex]
- At minimum three projections are needed: raw unread/history; exact unread used to derive surface lifecycle; routine waiting demand consumed by the Waiting row, menu-bar signal, waiting events, and fallback navigation. [Codex]
- `hasUnreadNotification` is today used for two incompatible jobs: exact-surface waiting projection (`WorkspaceContentView.swift:92`, `ContentView.swift:8651`) and marking a focused surface read (`TabManager.swift:3416-3439`). Changing it to signal semantics fixes suppression rendering but breaks read-marking; keeping it raw leaks suppression into waiting visuals. There is no consumer migration table. [Codex]
- The tab-level aggregation rule is never stated. `NotificationIndexes` is keyed by tab (`unreadCountByTabId`, `TerminalNotificationStore.swift:640`) while suppression is per surface and `TerminalNotification.surfaceId` is optional. A split holding one suppressed and one ordinary surface has undefined behavior. This is precisely where the plan's own "index drift" risk will materialize, and the plan's mitigation does not reach it. [Claude]
- Failure mode is leakage, not a crash: badge and menu tooltip disagree, one surface appears in two counters, focus stops marking suppressed history read. Every local implementation looks plausible; the product becomes inconsistent. [Codex]

### 1.4 Neither modifier has a lifecycle end [Claude, Codex, Gemini]

Three models, three angles, one conclusion.

- **Stale flags accumulate.** The Flagged Agents row's entire design justification is "zero flags, zero footprint; a new element appearing is a stronger signal than an existing button changing color." Once permanently non-zero, that property is destroyed. [Claude]
- **Zombie flags on process death.** Nothing defines what happens to a flag when the underlying Ghostty PTY process exits, zero or non-zero. A dead surface keeps its flag up forever. [Gemini]
- **Agents will not lower reliably.** An agent that solves a problem it previously flagged will most likely keep working and leave the flag up. Rated low likelihood to hold. [Gemini]
- **Overnight suppression outlives its purpose.** A surface suppressed at 11pm for a sweep is still suppressed at 9am when the operator starts working in it interactively. Nothing signals it, nothing clears it, and by design there is no indicator to notice it by. [Claude]
- **No bulk clear, no expiry, no auto-lower** (explicitly out of scope), **no rate limit** (the spec says so in as many words: "no enforcement mechanism, no soft cap, no rate limit"). [Claude, Gemini]
- **Close/prune semantics undefined.** `SurfaceMetadataStore.removeSurface` uses `queue.async` (`:579`) while writes use `queue.sync`, opening a visible stale-count window on close. No acceptance item covers "flag clears when its surface closes." [Claude] Codex frames the same gap as "close/prune must remove the cache entry without pretending an operator or agent lowered it."
- Shared prediction: operators will ask for `c11 lower-flag --all`, and the day they routinely use it as cleanup is the day the manual lifecycle is proven failed. [Gemini]

### 1.5 `by: operator | agent` is unsound and misses its purpose [Claude, Codex]

- It is a caller-settable field on a socket with no per-caller authentication, and the plan explicitly adds "an explicit socket field for trusted operator-originated actions." Agents and operator shells run as the same user and reach the same local socket. Any agent can write `operator`. [Claude, Codex]
- Its entire justification is trust: letting a dismissed agent distinguish "seen and deferred" from "nobody looked." A field whose only value is trust, with a caller-settable value, is worse than no field: it is a signal that will silently lie. [Claude]
- Even granting trust, the mechanism does not work. A stopped agent is not subscribed to `c11 events tail`. Emitting `flag.lowered` does not deliver the dismissal into the agent's PTY or conversation. [Codex]
- Launch-time attribution is wrong for the documented primary use case: an orchestrator agent running `launch-agent --suppressed` for a child is not the operator, yet the plan labels launch-time modifiers operator-originated. [Codex]
- Convergent alternative: derive origin from the transport (banner/UI actions use an internal operator-only call path; CLI and socket record claimed actor or default to agent), or demote `by` to advisory audit provenance and stop leaning on it in the skill text.

### 1.6 The ⌥V selector is not a queue [Claude, Codex, Gemini]

- **It latches.** Opening a flag does not lower it, so repeated ⌥V returns to the same surface forever. The operator cannot survey the second flag without dismissing the first, even when the first needs a decision they are not ready to make. Oldest-first is fair only if dequeue occurs. [Codex]
- **It inverts the key's recency character.** ⌥V today goes to the latest unread, so its destination is contextually close to what the operator was just doing. Oldest-first makes the destination by construction the least recent thing. [Claude]
- **It can yank the operator across workspaces.** The flag queue is global, so ⌥V can pull the operator out of the workspace they are actively working in, for something raised twenty minutes ago, at a moment they chose for a different reason. [Claude]
- **The inverse gap:** with no cross-workspace flag dashboard, a flag raised in a background workspace leaves the operator hunting manually for the violet mark if they miss or clear the OS notification. [Gemini]
- Alternatives named across reviews and worth deciding deliberately rather than by default: latest-first for flags too; oldest-first within the current workspace before crossing; a soft current-workspace preference; a per-invocation cycle cursor that advances after each successful open and resets when the active set changes.

### 1.7 Suppression is invisible and unenumerable, in its own dominant use case [Claude, Gemini]

- The spec names the shape: "an orchestrator dispatches a fleet of workers; suppressing the subagents is what makes that fleet legible." The plan adds `flag.list` with deterministic ordering and adds no equivalent for suppression. [Claude]
- Combined with the deliberate no-visual-indicator rule and the accepted cost that a finished suppressed agent and a stalled one both read idle, an orchestrator with thirty suppressed children has no way to enumerate them, no way to tell finished from stalled, and no per-surface indicator. Recourse is `get-metadata` one surface at a time. [Claude]
- The operator staring at thirty agents cannot tell background suppressed tasks from genuinely idle ones without querying metadata; their mental model must perfectly cache the launch state of every agent. [Gemini]
- "Return attention fields in machine-readable launch/list results" appears as one line in Phase 2 with no acceptance-checklist item and no test. Both reviewers want it promoted to a first-class, tested output.

### 1.8 Aggregation scope is ambiguous and quietly expands beyond the spec [Claude, Codex]

- The plan says the Flagged Agents row "follows that existing scope," which for `TerminalNotificationStore.shared` is app-global (`Sources/TerminalNotificationStore.swift:631-646`; every sidebar cluster reads the global unread count at `ContentView.swift:10695-10718`). The binding spec keeps c11 chrome workspace-local (`docs/c11-flagged-agent-plan.md:316-323`). [Codex]
- The plan simultaneously adds `WorkspacePulseSummary.flaggedCount`, which is per-workspace. Two different flag counts can be visible at once in adjacent chrome, and the plan never states whether they should agree or how the operator reads the difference. [Claude]
- "Follows the existing scope" is being used to conceal a real product-scope change. Either make the row selected-workspace-local as specified, or amend the contract explicitly and add tests. [Codex]

### 1.9 The single attention service is a responsibility list, not an architecture [Claude, Codex]

- `SurfaceAttentionService` is assigned metadata mutation, epoch ownership, cache refresh, notification-index refresh, event emission, direct delivery, restore, transfer, close, and prune (`task_...md:51-53`). That is a god object spanning a serial queue, the main actor, and `UNUserNotificationCenter`. [Codex]
- Restore, live raise, reason revision, transfer, close, prune, generic replace, and launch stamping do not share side effects, and no operation-mode table exists. "Route or reject" leaves a protocol decision to the implementer. Predicted outcomes: redelivering notifications during restore, silently lowering flags on close, resetting epochs on transfer, inventing `by` for generic replace, or accumulating ad hoc Boolean parameters until the "single boundary" is harder to reason about than the seams it replaced. [Codex]
- No lock ordering is written down. The service must serialize over a store using `queue.sync` for writes (`:621`, `:666`) and `queue.async` for removal and prune, hop to main for projection, and respond only after the commit is observable, all without `DispatchQueue.main.sync` (forbidden by `CLAUDE.md` policy). That is a two-queue-plus-main-actor commit protocol over a mixed sync/async store, easy to write as a rare deadlock or a rare stale response. [Claude]
- Codex's alternative, which addresses both: a pure `AttentionTransition` reducer returning an explicit effect set, plus a narrow coordinator that atomically commits metadata/epoch state and then applies typed effects. Restore, transfer, and close use different reducer inputs and cannot inherit live-raise effects.

### 1.10 The metadata source timestamp is the wrong home for the flag epoch [Claude, Codex]

- Source timestamps mean "when this value was written." A reason revision is a real value write and should update it. Reinterpreting it as an immutable epoch makes metadata provenance lie. [Codex]
- Mechanically, the plan's requirement that an active-to-active reason revision preserve the original epoch is not the store's current behavior: the merge path at `SurfaceMetadataStore.swift:741` unconditionally writes `sblob[k] = SourceRecord(source: source, ts: ts)`, and that line is not in the plan's owned-change list. (The same-source same-value no-op guard at `:634` returns `false` without touching `ts`, which is a different path.) [Claude, Codex `:699-741`]
- Both models want an explicit `flag_epoch` / `flag_raised_at` sidecar with stated invariants, or a transactional attention record in the store, rather than overloading `SourceRecord.ts`.

### 1.11 The validation path does not exist as described [Codex primary, Claude secondary]

- `.github/workflows/ci.yml:203-232` marks host-bound `c11Tests` `continue-on-error: true`, so host regressions merge green. [Codex]
- The workflow never invokes the Bonsplit test target, and Phase 4/5 changes land in the submodule. [Codex]
- `.github/workflows/test-e2e.yml` does not exist on this branch; it was removed in `7cbc27d31`. `scripts/run-e2e.sh` still targets upstream `manaflow-ai/cmux`, not this fork. [Codex]
- Combined with the plan's absolute prohibition on local test execution, every integration assertion can fail while the PR merges. Codex's phrase: validation theatre, not risk mitigation.
- Claude prices the same constraint differently: a 4-lifecycle by 2-flag by 2-suppression matrix plus edge transitions plus idempotency, round-tripping through PR CI, is a slow inner loop for the most assertion-dense part of the ticket, and the plan's risk section does not mention schedule at all. Mitigation: make the reducer table-driven so the whole matrix can be got right in one or two CI rounds.

### 1.12 There is no way to know whether the feature worked [Claude primary, Codex and Gemini implicitly]

- The motivation makes a falsifiable claim (scan cost grows linearly with fleet size; flags fix it). The plan ships four event types that would make measurement trivial and never proposes reading them. Nothing counts flags raised per week, flag lifetime before lower, `by` distribution, or the fraction of agents that ever flag against the spec's stated 9-in-10 target. [Claude]
- Codex's early-warning list is the same instinct expressed as invariants: same surface in both flagged and waiting counts; cache entries without matching canonical metadata; repeated `raised` epochs without an update marker; signal-count divergence across sidebar, status item, ⌥V, and workspace pulse; animation subscribers exceeding visible eligible marks; OK socket response with no snapshot revision inside a bounded interval.
- Gemini's version is behavioral: the day operators routinely run a bulk-clear command is the day the manual lifecycle is proven failed.
- Cost is near zero; `c11 events tail` already exists as the source.

---

## 2. Unique Concerns

Raised by exactly one model. Each is independently worth investigating; several are severe.

### Claude only

1. **Color-blind operators cannot see a flag in either mark renderer. Claude calls this the most serious gap in the plan.** The prerequisite doc's thesis is that shape carries lifecycle so color is free for the flagged modifier, framed explicitly as an accessibility repair. The flagged modifier then spends only color. For a protanope or deuteranope, flagged-idle and ordinary-idle are the same shape in near-identical values. Motion partially covers this, and the plan makes Reduce Motion a hard override on all flag motion. So Reduce Motion plus color-vision deficiency equals flagged being undetectable in both mark renderers, which are the fleet-scan channel and the feature's entire stated purpose. The spec hands over the fix and walks past it: "Opacity is now a completely free channel, unused by lifecycle, flagged, or suppressed." Every accessibility item in the plan is VoiceOver labels and Reduce Motion, with no color check at all.

2. **One PR for seven phases is the wrong unit of work.** Roughly twenty files including the four largest in the repository (`ContentView.swift` 15,476 lines, `AppDelegate.swift` 14,654, `Workspace.swift` 12,908, `GhosttyTerminalView.swift` 10,073), a public API change to a vendored submodule, a new socket domain, four CLI commands, two launch flags, four event types, two mark renderers, a new interactive AppKit overlay, six locales, a skill contract with a manual sync step, an unresolved product policy decision, and a bespoke performance campaign with no existing instrument. The stated review budget (one correctness review, one fix pass, one re-review) is not real for this diff. The natural seam is Phases 0-3 (model, primitives, signal layer: testable, shippable, no visual surface) versus Phases 4-6 (renderers, submodule, banner, localization). The plan's own commit-unit list already draws it.

3. **No time estimate anywhere, and no rebase cadence.** Seven phases across the four most-contended files in a repo whose default workflow runs a parallel delegator fleet. Without a duration there is no threshold at which anyone notices the ticket running long, and every rebase risks silently reverting an attention-path edit.

4. **The 40+ animating marks target is unreachable by construction.** The fleet protocol demands at least 20 active agent surfaces so 40+ marks exist. The plan also correctly requires marks to unsubscribe when scrolled out of the tab bar, in collapsed panes, in unselected workspaces, or while the app is inactive. Twenty surfaces in one workspace means most tabs are scrolled out and must not animate; spreading across workspaces means the background ones must not animate. Either the pause rules are broken (the gate measures a bug) or the gate measures far fewer than 40 marks (the fleet-scale framing is decorative). Nobody has reconciled the two requirements.

5. **The gate would run on a Debug build.** `dlog` is DEBUG-gated by necessity (an ungated `dlog` breaks the Release build per `CLAUDE.md`), so the measurement runs on a build whose SwiftUI and render characteristics differ materially from the Release build users get. The shipped product would be gated on a number from a different product.

6. **The plan's headline reducer is already duplicated at HEAD and is about to be tripled.** `Sources/Sidebar/SidebarActivityProjector.swift:55` and `Sources/ContentView.swift:11437` each independently compute the identical reduction `suppressed && !flagged && state == .waiting ? .idle : state`. The plan adds `SurfaceLivenessDeriver`, `AttentionModel`, and a Bonsplit presentation path as further consumers, lists "spec precedence implemented differently in two renderers" as a risk with the mitigation "one shared pure presentation value," and then keeps projection logic in all three files while saying nothing about deleting the `ContentView.swift:11437` duplicate. The risk is not mitigated; it is pre-existing and being doubled.

7. **C11-183 shipped behavior contradicting a spec that already existed, four commits ago, and nothing prevents a repeat.** Verified: `Sources/ContentView.swift:11453` reads `guard !suppressed, !staticMarks else { return nil }` with no `flagged` term, so flagged working runs base motion today, contradicting the binding spec's breathe-for-every-flagged-non-waiting-state requirement. The plan reverses it on spec authority alone. If C11-183's behavior was a considered simplification, the reversal deserves an argument; if an oversight, the process gap deserves a sentence.

8. **No rollback path and no kill switch.** This changes the default attention behavior of the whole application: waiting counts, ⌥V destination, both mark renderers, the sidebar, external delivery. The regressions that matter (a lost `waiting.entered` edge, a double-counted flag, ⌥V going somewhere wrong) are invisible until the operator misses something, the worst possible detection profile. The only remedy on offer is reverting a seven-phase branch. A defaults-backed switch forcing signal eligibility to equal raw eligibility is cheap insurance, and the `Static marks` user default is an in-codebase precedent.

9. **`flaggedCount` and the navigable set can disagree.** The plan skips stale or unopenable surfaces in navigation but presumably still counts them. A row reading "3 flagged" that jumps to only one is a correctness bug already written into the plan. Count-equals-navigable-set is not in the acceptance checklist.

10. **`restoreFromSnapshot` has no validation seam at all.** Verified: it assigns `metadata[...] = values` and `sources[...] = sources` wholesale with zero validation (`:566-573`); the only special-cased key is `flash_state`, dropped at the call site in `Workspace.swift:7606`. A corrupted or hand-edited snapshot can inject a multi-kilobyte multi-line `flag` value that bypasses every validator the plan builds and renders it in a banner floating over terminal pixels. The plan asserts restore "enters through explicit service hooks"; the actual function has nowhere to hook. (Codex asks for restore to "fail closed" on malformed metadata but does not identify the missing seam.)

11. **The banner may break the focus responder chain.** `GhosttyTerminalView.swift:8809` (`isSearchOverlayOrDescendant`) walks the responder chain testing `v is NSHostingView<SurfaceSearchOverlay>` and string-matching `"BrowserSearchOverlay"`. Any interactive overlay, and the banner has an X button, must be known to this predicate or focus-clearing misclassifies it. The plan says "do not touch `hitTest()`" and "restore terminal focus" but never names this function. That the existing code resorted to string-matching a type name says the seam is not clean and the third overlay will not be free.

12. **The Bonsplit public API change is on the critical path and should be landed first.** `Tab` is `public`, `Hashable`, `Sendable`, with an all-`let` memberwise init. Adding an optional presentation value touches the init, the `from tabItem:` bridge, every construction site, controller create/update, transfer, and decode-with-default. Separately, `bonsplitActivityAnimationEnabled` is today a single environment key folding four conditions (`WorkspaceContentView.swift:225-230`); splitting it into base and explicit motion means finding every consumer inside the package. Reverting a submodule pointer mid-ticket is painful, and the repo's own submodule discipline makes iteration expensive. Land the Bonsplit seam as its own small submodule PR before the c11 work.

13. **Localization at Phase 6 is the wrong position.** The plan's own instruction is "stabilize English keys first," but "first" is scheduled last. User-facing strings are produced in Phase 2 (CLI help), Phase 4 (row), and Phase 5 (banner). In practice those get written as bare literals and Phase 6 becomes a hunt rather than a translation pass, which is exactly the failure `CLAUDE.md` warns about. Add localized keys at the moment each string is written. Note also that the translator subagent stage and the mandatory `scripts/sync-installed-skills.sh` step are the last two items in a long chain, the position of maximum schedule pressure, and `CLAUDE.md` marks the sync a HARD RULE precisely because it has been skipped before.

14. **"Dial in the violet in the tagged build" is a design decision hiding inside a validation gate.** If `#9D8AD9` does not hold at 9pt against `#E8E8E8` on the void, that is discovered at the end of the longest phase chain, competing with the rest of the visual pass for the same attention.

### Codex only

15. **The ticket identifier is already spent.** Git history contains `46566ed14 Plan C11-184 surface tab agent states` and merged PR #360 at `dbdd75ec5` ("Show agent state on surface tabs"). The current Lattice task assigns the same short ID to a different feature. Search, release notes, branches, worktrees, review artifacts, and future incident reports all become ambiguous. This is not clerical trivia; it poisons every future handoff once it enters commits and PR titles. Rename before any commit uses it, or record an explicit alias.

16. **"Committed" is not "durable."** The plan requires the socket response only after the attention commit is observable and calls the modifiers persisted. The metadata store is in-memory (`Sources/SurfaceMetadataStore.swift:79-88`) and the session snapshot runs on an eight-second autosave cadence (`Sources/SessionPersistence.swift:17`, `Sources/TabManager.swift:5551-5557`). A successful response does not mean the flag survives a crash. This is worse than ordinary status metadata because the operator will trust "raised" more, and every unit test of the in-memory service passes while the central promise breaks.

17. **Bonsplit accessibility localization is unowned.** Phase 4 requires the surface tab to announce flag state and reason; Phase 6 translates only `Resources/Localizable.xcstrings`. Bonsplit owns its own seven `Localizable.strings` catalogs under `vendor/bonsplit/Sources/Bonsplit/Resources/<locale>.lproj/`, and its tab accessibility strings resolve inside the package. Either inject already-localized accessibility value/help through the generic presentation object, or add and translate generic Bonsplit keys in all seven package catalogs. The owned-file list and translator scope cover neither.

18. **Event payloads cannot represent a reason revision.** An active-to-active reason edit preserves the queue epoch but emits another `flag.raised {reason}` carrying no epoch ID, no original `raisedAt`, no revision marker, no `updated: true`. Overwatch and cron consumers cannot distinguish a new flag from a revision without racing a separate `flag.list` query. If external routing is a goal, events need enough identity to be consumed idempotently: an epoch identifier plus `raisedAt`, or a distinct `flag.updated`.

19. **External-delivery identity and retraction are unspecified.** "One updated direct notification" on revision requires a stable per-flag-epoch notification identifier; lowering should remove its pending or delivered request; a new epoch needs a new identifier. None is specified. Separately, suppression applied after a routine notification has scheduled can remove a pending or delivered `UNNotificationRequest` but cannot undo `NotificationSoundSettings.runCustomCommand`, which runs after scheduling (`TerminalNotificationStore.swift:1026-1041`). The product promise must be stated temporally: suppression prevents future routine delivery and retracts removable requests; it cannot retract external effects already executed.

20. **Flag reasons have no data-sensitivity policy.** Agent-authored strings are persisted in session snapshots, emitted into the event log, displayed over terminal pixels, and placed in lock-screen-capable system notifications. A 256-character cap is not a privacy policy. The plan needs a position on secrets and customer data, notification-preview expectations, and event/snapshot retention.

21. **Multi-window behavior is entirely absent.** With an app-global store, every window shows the same flagged count and may jump into another window. No tests exist for: two windows with flags in only one; closing one window; a notification click whose target window is not current; identical surface or workspace restore IDs across window contexts; whether the row count is per selected workspace, per window, or app-wide.

### Gemini only

22. **Flag thrashing and notification-center DoS.** The plan says repeated identical raises are idempotent. It says nothing about a malfunctioning agent in a loop that varies the reason string slightly on each raise. The UI thrashes and direct delivery floods the macOS notification center. Gemini predicts an emergency hotfix adding a rate limit, and frames the underlying issue plainly: an un-rate-limited pipeline from arbitrary agent processes straight to the OS notification center is a loaded gun.

23. **Typing into a flagged surface should arguably count as acknowledgment.** Terminal input is the literal definition of a human intervening. If an agent says "I am blocked, I need a human," and the human starts typing into the PTY, the human has intervened. Requiring them to also click a small X is double work. Whether or not this becomes the rule, the plan should defend the choice rather than inherit it.

24. **Banner interaction and layout hazards beyond focus.** Floating overlays over PTYs historically intercept clicks meant for the terminal, fail to track scrolling and resizing perfectly, and obscure top-line terminal content, which often carries a shell prompt, git status, or a vim status line. Gemini rates the plan's text-preservation argument (banner beats PTY resize) high-likelihood and its interaction-safety argument low. Specifically asks whether the `NSHostingView` banner tracks the surface through rapid window resize and pane splits, or visually detaches and lags.

25. **Flags bypassing `TerminalNotificationStore` erase the flag history.** By skipping the store for direct delivery, flags bypass the single source of truth for historical events. If the operator clears an OS notification, there is no log of what was raised while they were away from the desk.

26. **The composite morning-after scenario.** Twenty agents overnight, fifteen suppressed. A network blip fails all twenty. Five normal ones go to waiting; fifteen suppressed try to flag; five of those crash before they can. The operator wakes to ten OS notifications, five waiting marks, and five silently dead suppressed agents that look perfectly idle, trusts the system, assumes the silent ones succeeded, and makes a downstream commit on missing data. This is the single most concrete articulation across all three reviews of why suppression-without-liveness is dangerous.

---

## 3. Assumption Audit (merged and deduplicated)

### Load-bearing, assessed as false or unsupported

| # | Assumption | Verdict | Raised by |
|---|---|---|---|
| A1 | The binding inputs (spec, task description, staged skill, plan) agree on suppression and notifications | **False.** Direct contradiction across four documents | Codex, Claude |
| A2 | A 1 ms p95 keystroke-to-paint delta is measurable on this codebase | **False as things stand.** No harness; only instrument is DEBUG-only and threshold-truncated | Claude, Codex |
| A3 | The measurement proxy is valid | **Unsupported.** Debug-build numbers gating Release behavior | Claude |
| A4 | 40+ concurrently animating marks is a constructable configuration | **False.** Contradicted by the plan's own unsubscribe rules | Claude |
| A5 | One signal-eligibility projection serves every consumer | **False.** Flagged-waiting needs exact unread without duplicating routine waiting demand | Codex, Claude |
| A6 | Signal eligibility can be layered onto the existing index builder | **Under-specified.** Tab-keyed indexes vs per-surface suppression; no aggregation rule for splits | Claude |
| A7 | The metadata source timestamp is a sound flag epoch | **Not with the current write path.** `:741` unconditionally overwrites `ts`; also makes provenance lie | Claude, Codex |
| A8 | The serialized service commit is durable | **False under crash.** In-memory store plus 8-second autosave | Codex |
| A9 | `by: operator \| agent` is trustworthy attribution | **False.** Caller-settable on an unauthenticated same-user socket | Claude, Codex |
| A10 | An agent can react differently to operator dismissal | **Unproven.** A stopped agent is not subscribed to the event stream; dismissal never reaches its PTY or conversation | Codex |
| A11 | Launch-time modifiers are operator-originated | **False for the primary use case:** an orchestrator agent launches suppressed children | Codex |
| A12 | PR CI executes every required assertion | **False.** Host tests `continue-on-error`; Bonsplit target never invoked | Codex |
| A13 | The E2E workflow can be triggered | **False.** `test-e2e.yml` absent since `7cbc27d31`; `run-e2e.sh` targets upstream | Codex |
| A14 | The Flagged Agents row follows a harmless existing scope | **False.** Existing store is app-global; binding spec keeps chrome workspace-local | Codex, Claude |
| A15 | The Phase 3 notification question is a one-line branch | **Moderate at best.** A "yes" falsifies a binding spec sentence, which is an amendment, not a branch | Claude |
| A16 | The banner is purely additive to focus handling | **Probably false.** `isSearchOverlayOrDescendant` must learn about any interactive overlay | Claude |
| A17 | The floating banner is interaction-safe over a PTY | **Low.** Click interception, resize/scroll tracking, obscured top-line content | Gemini |
| A18 | Agents will reliably lower flags when they unblock | **Low.** Agents are bad at cleanup; a solved problem is left flagged | Gemini |
| A19 | Operators will manually dismiss every flag | **Medium, decaying.** Becomes a chore at fleet size; leads to flag blindness | Gemini |
| A20 | Suppressed agents need no visual indicator at rest | **Medium.** Clean, but destroys state legibility across thirty agents | Gemini, Claude |
| A21 | Suppression cancellation is reversible | **Partly.** Requests may be removable; an already-run custom command cannot be undone | Codex |
| A22 | The operator will run `scripts/sync-installed-skills.sh` | **Historically unreliable.** `CLAUDE.md` marks it a HARD RULE because it has been skipped; scheduled last | Claude |

### Invisible assumptions (never stated, never tested)

1. That flag rarity self-regulates. Inherited from the spec, which concedes "no enforcement mechanism, no soft cap, no rate limit." A novel bet on social self-regulation among agents, with no precedent and nothing shipped that would detect losing it. [Claude, Gemini]
2. That an operator can tell a suppressed surface from an ordinary one when they need to. They cannot, by design. [Claude, Gemini]
3. That flags and suppression are transient. Both are sticky, survive relaunch, have no expiry and no bulk clear. [Claude, Gemini]
4. That a flag's meaning survives the death of the process that raised it. Undefined. [Gemini]
5. That the flag color is legible to everyone. No color-vision consideration anywhere in a plan whose prerequisite was justified as an accessibility repair. [Claude]
6. That `main` will hold still across a seven-phase branch touching the four largest files in the repo. [Claude]
7. That the tagged-build visual pass is a validation rather than a design session. `#9D8AD9` is called "a starting value, dialled in the tagged build." [Claude]
8. That flag reasons contain nothing sensitive. [Codex]
9. That there is one window. [Codex]
10. That the raw notification history is an acceptable place for flags to be absent from. [Gemini]

---

## 4. The Uncomfortable Truths

Ordered by how many models say a version of it.

1. **The feature's headline case may reach the operator through nothing at all.** [all three] The binding spec calls flagged-plus-suppressed the most valuable combination in the feature. Under the current faithful reading it gets no system notification, and its in-app alarm flash stops when the app is inactive, which is exactly the overnight-sweep scenario the case was designed for. Nobody has said this out loud in the plan.

2. **The hardest-labeled gate is the softest thing in the document.** [Claude, Codex] Everything else in the plan is executable. The one item labeled "hard pre-merge gate" is a wish, because the instrument that would produce its number does not exist and building it is unscoped.

3. **The plan's level of detail creates false confidence.** [Codex, Claude] Many paragraphs specify colors, timings, and commit grouping while state projections, actor provenance, persistence boundaries, and the executable test path remain unsettled. Claude's version: the plan is disciplined about process and light about product. It is meticulous on threading, submodule ancestry, bypass closure, and evidence capture; it is thin on what the operator does when they lose track of their suppressed fleet, what happens when flags accumulate, whether cross-workspace oldest-first ⌥V is pleasant to use, and whether a color-blind operator can see any of it. Those are week-two questions.

4. **The system's correctness depends on discipline it does not enforce, from actors known to be undisciplined.** [all three] Gemini states it most bluntly: the plan assumes agents are polite and competent; in reality agents are chaotic, and giving them a direct un-rate-limited pipeline to the macOS notification center is a loaded gun. Claude's version is the rarity bet with no telemetry. Codex's version is that "one service owns everything" substitutes a responsibility list for an operation protocol.

5. **The feature is unfalsifiable as planned.** [Claude, Codex] No counter, no rate, no baseline, no follow-up. Six weeks out, "did this help?" is answered by whoever speaks first.

6. **"Follows the existing scope" is concealing a real product-scope change.** [Codex, Claude] Workspace-local to app-global aggregation, with duplicate global rows across windows, presented as inheriting a harmless precedent.

7. **The oldest-first selector is not a queue, because nothing advances it.** [Codex, Claude, Gemini] It is a latch on the most-used key in the sidebar cluster, and its feel is changing without discussion.

8. **The strongest persistence promise is only eventually durable.** [Codex] The operator will trust "raised" more than any other metadata, and it is the value most likely to be lost in a crash window.

9. **The unit of work is wrong.** [Claude] A program with a ticket number: seven phases, twenty files, a submodule API change, a translation stage, an unresolved product policy question embedded as a placeholder, and a bespoke performance campaign, with no duration on any of it and a review budget of one pass.

10. **The ticket number collision is not clerical trivia.** [Codex] It will poison every future search and handoff the moment it enters a commit or a PR title.

11. **Suppression may be over-conceptualized.** [Gemini] It is functionally a mute button; treating it as a core architectural concept may be over-engineering a problem that easier clearing of the waiting state would solve. This is the one truth the other two models do not reach, and it is worth a deliberate rebuttal rather than silence.

---

## 5. Consolidated Hard Questions for the Plan Author

Deduplicated across all three reviews and grouped. Source model in brackets. Questions marked **[BLOCKER]** are ones at least one reviewer says must be answered before implementation starts.

### A. Notification policy and the headline case

1. **[BLOCKER]** Does a flag on a suppressed surface fire a system notification? Resolve before Phase 1, not after Phase 2. [Claude, Codex]
2. If the answer is no: state plainly in the plan that the feature's headline case reaches an absent operator through no channel, and address that its in-app flash also stops when the app is inactive (`WorkspaceContentView.swift:226` gates on `scenePhase == .active`). [Claude]
3. If the answer is yes: which exact spec sentence is being rewritten, and will the task description and the staged skill be amended too, or only `docs/c11-flagged-agent-plan.md`? [Claude, Codex]
4. What does suppression promise after `NotificationSoundSettings.runCustomCommand` has already executed? State the promise temporally. [Codex]
5. If a suppressed agent crashes without raising a flag, how does the operator distinguish failure from success when it sits at idle? [Gemini]

### B. State projection and consumer migration

6. **[BLOCKER]** When one surface is both flagged and truly waiting, does it increment both Flagged Agents and Waiting Agent? If not, which exact projection feeds each count? [Codex]
7. **[BLOCKER]** What are the explicit notification views (raw history, exact lifecycle unread, routine waiting demand), and which existing call site consumes each? Produce a checked-in consumer matrix. [Codex]
8. Does focusing a suppressed surface mark its retained unread record read? Which API preserves that behavior without leaking a waiting signal? [Codex]
9. What is the tab-level aggregation rule for signal eligibility? Indexes are keyed by tab (`unreadCountByTabId`), suppression is per surface, `surfaceId` is optional, and a tab can hold several surfaces via splits. State the rule for a tab holding one suppressed and one ordinary surface. [Claude]
10. Which single function owns index rebuild and edge emission? `emitWaitingEdges` today derives its delta from state captured inside `notifications.didSet`, and you are adding a second rebuild trigger from attention mutations. Where is the structural invariant preventing double-emit and lost edges, as opposed to a review-checklist item? [Claude]
11. Where does the `SidebarActivityProjector.swift:55` versus `ContentView.swift:11437` duplication get deleted? The same reduction exists twice at HEAD and you are adding at least two more consumers. [Claude]

### C. Service architecture, ordering, and durability

12. **[BLOCKER]** What exact effects occur for each of: live raise, reason revision, restore, launch stamp, transfer, close, prune, generic keyed clear, clear-all, replace? Produce the operation-mode table. "Route or reject" is not a protocol. [Codex]
13. Write down the lock ordering for `SurfaceAttentionService`. It serializes over a store using `queue.sync` for writes and `queue.async` for removal and prune, hops to main for projection, and must not respond before the commit is observable, all without `main.sync`. Show the sequence. [Claude]
14. Is an OK socket response required to mean in-memory observable, or crash-durable? What happens inside the current eight-second autosave window? [Codex]
15. Where is the original flag epoch stored, and how does a reason revision update the string without overwriting `SourceRecord.ts`? Note `SurfaceMetadataStore.swift:741` unconditionally writes `SourceRecord(source:ts:)` and is not in your owned-change list. [Claude, Codex]
16. Have you considered the pure-reducer-plus-typed-effects alternative to a single service that owns metadata, cache, indexes, events, delivery, and lifecycle cleanup? If rejected, why? [Codex]

### D. Attribution and the agent feedback loop

17. How is `by: "operator"` verified? It is a caller-settable field on an unauthenticated same-user socket and its entire purpose is trust. Either derive it from the transport (banner X equals operator, socket equals agent, no override) or document it as advisory and stop leaning on it in the skill text. [Claude, Codex]
18. How does an agent that has stopped receive an operator dismissal and its `by` value? If it cannot, why does the spec claim the agent can distinguish "seen and deferred" from "nobody looked"? [Codex]
19. Who is the actor when an orchestrator agent runs `launch-agent --suppressed` for a child, and why does the plan label every launch-time modifier operator-originated? [Codex]

### E. Lifecycle, decay, and abuse

20. What happens to a raised flag when the underlying Ghostty PTY process exits, zero or non-zero? Does the flag stay up on a dead pane forever? [Gemini]
21. What clears a suppression that has outlived its purpose? Concretely: the operator suppresses eight subagents at 11pm, the sweep finishes at 3am, and at 9am they start working in those surfaces. What tells them, and what clears it? [Claude]
22. How do you prevent a malfunctioning agent from spamming the notification center by raising flags rapidly with slightly varied reason strings? Idempotence on identical raises does not cover it. [Gemini]
23. If an operator starts typing into a flagged surface's terminal, why is that not sufficient proof they are addressing the flag? [Gemini]
24. What is the plan for the day the Flagged Agents row is permanently non-zero, given that "zero flags, zero footprint" is its entire design justification? [Claude]

### F. Enumeration, scope, and navigation

25. How does an orchestrator enumerate its thirty suppressed children? There is no visual indicator, no `suppress.list`, and no tested attention column. Per-surface `get-metadata` is not an answer at fleet scale. [Claude]
26. Is the Flagged Agents row selected-workspace-local, window-local, or app-global, and why does that differ from the binding spec's workspace-local UI? [Codex]
27. Are there two flag counts on screen at once (global footer row versus per-workspace `WorkspacePulseSummary.flaggedCount`)? Should they agree? What does the operator read? [Claude]
28. How should two windows render and navigate an app-global flag count? What are the tests for flags in only one window, closing a window, and a notification click targeting a non-current window? [Codex]
29. How does repeated ⌥V reach the second active flag without lowering the first? [Codex]
30. Why is oldest-first, cross-workspace the right ⌥V behavior? Defend it as operator experience, not queue fairness. It inverts the key's current recency property and can pull the operator across workspaces at a moment they chose for something else. [Claude]
31. When `flaggedCount` includes a stale or unopenable surface that navigation skips, what does the operator see? Where is the count-equals-navigable-set invariant and its test? [Claude]
32. Why are direct flag notifications excluded from raw `TerminalNotificationStore` history? How does an operator review flags raised while away from the desk? [Gemini]

### G. Events, delivery identity, and external consumers

33. Does `flag.raised` represent a new epoch or a reason update, and how can Overwatch consume it idempotently? Consider an epoch identifier plus `raisedAt`, or a distinct `flag.updated`. [Codex]
34. What stable notification identifier represents a flag epoch, and what happens to pending and delivered requests on revise and on lower? [Codex]
35. Are flag reasons allowed to contain secrets or customer data, given their persistence in snapshots, emission into the event log, display over terminal pixels, and exposure in lock-screen-capable notifications? [Codex]
36. What validates `flag` on the restore path? `restoreFromSnapshot` assigns wholesale with zero validation and only `flash_state` is special-cased at the call site. A corrupt snapshot puts arbitrary multi-line text into a banner over terminal pixels. [Claude]

### H. The latency gate

37. **[BLOCKER]** What exact command produces the p95 keystroke-to-paint number? Name the binary, the script, the output format, the clock, the sampling window, trial count, warm-up, baseline ordering, and the subscriber-count debug seam. "We will build one" is unscoped work inside a plan with no schedule. [Claude, Codex]
38. How do you construct 40+ concurrently animating marks when your own correctness rules require off-screen, collapsed, unselected-workspace, and background marks to unsubscribe? These two requirements contradict; which gives? [Claude]
39. Why is a Debug-measured 1 ms delta the right proxy for Release behavior? [Claude]
40. How is a <=1 ms delta distinguished from run-to-run noise on an unpinned machine running twenty live agents? [Claude, Codex]
41. If the gate cannot be run at all, which rung of the fallback ladder ships? Decide now, in writing, rather than under schedule pressure at the end of Phase 5. Note the lower rungs (static marks, static violet) delete most of the visual design Phases 4 and 5 exist to build. [Claude]

### I. Validation and CI

42. **[BLOCKER]** Which CI job hard-fails the new host-bound tests? `ci.yml:203-232` marks `c11Tests` `continue-on-error: true`. [Codex]
43. Which CI job runs Bonsplit tests? The workflow does not invoke the package test target today. [Codex]
44. What fork-owned workflow replaces the absent `.github/workflows/test-e2e.yml` (removed in `7cbc27d31`), and what replaces `scripts/run-e2e.sh`, which still targets upstream `manaflow-ai/cmux`? [Codex]
45. Given no local test execution, is the 4-lifecycle by 2-flag by 2-suppression matrix structured as a single table-driven test that can be got right in one or two CI rounds? [Claude]

### J. UI integration

46. Does the banner's X button ever become first responder? If yes, `isSearchOverlayOrDescendant` (`GhosttyTerminalView.swift:8809`) must learn about it. If no, state that as a design constraint and test it. [Claude]
47. Does the floating `NSHostingView` banner track the surface through rapid window resize and pane splits, or does it visually detach and lag? Does it intercept clicks meant for the terminal? What top-line terminal content does it obscure? [Gemini]
48. How does a color-blind operator see a flag in the mark row? Shape is spent on lifecycle, motion is killed by Reduce Motion, and the spec explicitly names opacity as a free unspent channel. Spend it, add a second shape channel, or write down the accepted cost. [Claude]
49. Where are the Bonsplit accessibility translations owned, and how are all seven package locales validated? [Codex]

### K. Scoping, identity, and process

50. **[BLOCKER]** Why is this feature reusing `C11-184`, already present in git history (`46566ed14`) and merged PR #360? What is the migration to an unused identifier? [Codex]
51. Why one PR? State the reason, or split at Phase 3 or 4. Your own commit-unit list already draws the seam. [Claude]
52. How long is this? No estimate appears anywhere in a seven-phase plan. [Claude]
53. What is the rebase cadence against `main`, given you are branching across the four largest files in a repo whose default workflow runs parallel delegators? [Claude]
54. What is the rollback if signal eligibility regresses in production? These regressions are invisible until the operator misses something. Is reverting a seven-phase branch really the plan, when a defaults-backed passthrough switch costs almost nothing and `Static marks` is the precedent? [Claude]
55. How will you know, in six weeks, whether flags worked? Name the number. The events stream already exists as the source. [Claude]
56. Why did C11-183 ship a flagged-motion behavior contradicting a spec written before it, and what in the process prevents the next prerequisite ticket from doing the same? [Claude]
57. Should the Bonsplit public API change land as its own small submodule PR before the c11 work, so the API is settled and pushed before anything depends on it? [Claude]
58. Should localized keys be added at the moment each string is written (Phases 2, 4, 5) rather than collected in a Phase 6 hunt, and who guarantees `scripts/sync-installed-skills.sh` runs given it is the last item in the chain? [Claude]
59. Is suppression conceptually load-bearing, or is it a mute button being promoted to architecture when easier clearing of the waiting state would serve? Rebut deliberately rather than by silence. [Gemini]

---

## Appendix: Where the Models Disagreed

Worth noting, because disagreement is information.

1. **Severity of the banner design.** Claude treats the portal-mounted banner as sound engineering that correctly avoids a PTY-resize bug, flagging only the responder-chain seam. Gemini treats floating overlays over PTYs as a known-bad pattern on interaction grounds. Both are compatible: the choice is right, the interaction surface is under-specified.

2. **Whether the plan is too big or too unsettled.** Claude's diagnosis is scope (a program with a ticket number, split it). Codex's is architecture (the contracts contradict, revise before coding). These prescribe different first moves. They are reconcilable: the architecture revision applies to Phases 0-3, which is also the first half of Claude's proposed split, so doing Codex's revision first and shipping Claude's first half satisfies both.

3. **Whether suppression deserves to exist.** Only Gemini questions the primitive itself. Claude and Codex accept it and attack its ergonomics and enumeration. Gemini's challenge is the cheapest to answer and the most embarrassing to leave unanswered.

4. **Emphasis on accessibility.** Claude calls color-blindness the most serious gap in the plan. Neither other model mentions color vision at all. Given the prerequisite ticket was justified as an accessibility repair, single-model status here reflects coverage, not low severity.
