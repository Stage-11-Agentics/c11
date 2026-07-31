# Action-Ready Synthesis: c11-184-plan

## Verdict

**rework-then-rereview**

Reviewer verdicts disagreed sharply. Standard/Gemini alone said "ready to execute." Standard/Claude and Standard/Codex both said "needs revision — hours, not a rethink." Adversarial/Codex said "NOT READY, concern level high — the right next move is a short architecture revision, not coding." Adversarial/Claude said the plan is good but "about the wrong unit of work." All three evolutionary reviewers endorsed the architecture and asked for contract amendments before handler code is written.

Per the cautious-bias rule, the verdict tracks the adversarial reads. To be precise about what "rework" means here: **no reviewer asked for a redesign of the core model.** Eight of nine explicitly endorsed it (orthogonal persisted modifiers over an unchanged four-case lifecycle, canonical metadata as substrate, one serialized commit boundary, raw-vs-signal notification split, generic Bonsplit seam, portal-mounted banner). The rework is at the contract layer: the flag epoch has no durable representation in the store the plan names, the notification split needs three projections rather than one eligibility bit, the commit protocol is a responsibility list rather than an ordering, two binding documents still contradict the plan's own resolved decision, and the CI gates the plan leans on do not exist in this repository. That volume of contract change warrants a re-review of the revised plan before implementation, not a fresh planning pass.

I independently verified every code and repository claim used as a blocker basis. All of them held.

---

## Apply by default

### Blockers (plan is not yet executable as written)

- **B1: The flag epoch has no durable representation under the metadata write path the plan names**
  - Where in the plan: "Architecture and data flow → Canonical truth and typed projection", mutation semantics item 1 ("records/reuses the original active-epoch timestamp… An active-to-active reason revision preserves that original timestamp"), and "the metadata source timestamp as the raise time".
  - Problem: Verified at `Sources/SurfaceMetadataStore.swift:741` — the merge path unconditionally writes `sblob[k] = SourceRecord(source: source, ts: ts)` on any value change. The no-op preservation guard above it only fires for an *identical* value from the same source. A reason revision is a changed value, so the source timestamp moves forward, the flag drops to the back of the oldest-first queue, and an epoch preserved only in the in-memory index is lost on relaunch. `restoreFromSnapshot` cannot recover an epoch that was already overwritten.
  - Revision: Choose and specify one durable mechanism, and name `SurfaceMetadataStore.swift:741` as an owned change site. Option A: a paired canonical `flag_raised_at` / `flag_epoch` value written atomically with the reason (preferred by Adversarial/Codex and Evolutionary/Codex — "last write time" and "attention epoch start" are genuinely different facts). Option B: a narrowly scoped, explicitly-tested attention store transaction that changes the reason while preserving the existing `flag` source record timestamp (preferred by Standard/Codex — keeps the canonical model at two keys). Whichever is chosen, define its behavior under `mode=replace`, keyed clear, clear-all, lower-then-raise, transfer, and launch stamping, and add a test that raises A, revises to B, snapshots, restores, and asserts unchanged queue age and position.
  - Sources: Standard/Codex (blocking gap 1), Adversarial/Claude (A5, Q14), Adversarial/Codex (assumption audit, Q6), Evolutionary/Codex (§1, suggestion 2).

- **B2: "Route or reject" for generic metadata mutation of attention keys is left as an either**
  - Where in the plan: "The generic `surface.set_metadata` / `surface.clear_metadata` routes may not bypass that boundary. Route writes… through the service (or reject those keys there with a precise protocol error and require the flag family)."
  - Problem: The two alternatives have materially different attribution, timestamp, idempotency, and mixed-transaction semantics. Leaving the choice to the implementer means the protocol is undefined at the exact perimeter the plan says must be closed.
  - Revision: Decide it in the plan. Both reviewers who addressed it recommend **reject**: the `flag.*` methods become the sole mutation API for `flag` and `suppressed`; generic set / clear / replace / clear-all requests that would add, revise, or remove either key fail with a precise protocol error; both keys remain readable through `get-metadata`. Explicitly state what a mixed `mode=replace` payload does when it carries one attention key and one ordinary key (all-or-nothing rejection is the coherent answer), and state whether clear-all lowers a flag and emits `flag.lowered` and with which actor.
  - Sources: Standard/Codex (blocking gap 3, Q5/Q6), Adversarial/Codex (blind spot 2, Q9).

- **B3: The commit boundary is a list of responsibilities, not an ordering protocol**
  - Where in the plan: "One serialized `SurfaceAttentionService` … owns the complete commit boundary" plus the Phase 2 socket execution contract ("never use `DispatchQueue.main.sync`… complete the request after the serialized attention commit finishes").
  - Problem: The commit spans the metadata store's serial queue (which uses `queue.sync` for writes but `queue.async` for `removeSurface`/`pruneWorkspace`, verified at `SurfaceMetadataStore.swift:579`), the main actor (projection, notification store, banner host), and the asynchronous `UNUserNotificationCenter`. "Serialized" plus "no `main.sync`" plus "response only after the commit is observable" is implementable but is not derivable from the plan; re-derivation under deadline is exactly where `main.sync` or a stale response reappears. `UNUserNotificationCenter.add` is async and cannot participate in an atomic boundary at all.
  - Revision: Write the sequence down before Phase 1. Specify: which object holds pending socket responses; what happens when a second mutation for the same surface arrives mid-commit (per-surface serialization key); the response contract if the main hop never runs (app terminating); and whether events lead or trail the projection (can an Overwatch consumer observe `flag.raised` before `flag.list` reflects it — decide and document). Separately, split the transition into **commit** (validate, canonical write, epoch, typed projection, signal index, event emission) and **effects** (system notification, custom command), with an idempotency key derived from surface plus flag epoch. A failed effect must not roll back canonical state; the socket response reports committed state plus a delivery outcome such as `scheduled | disabled | failed`.
  - Sources: Standard/Claude (blocking 2, Q2/Q3), Adversarial/Claude (C7, Q11), Adversarial/Codex ("one service owns everything" failure mode, Q8), Evolutionary/Codex (§2, suggestions 1/3).

- **B4: The notification refactor needs three projections, a publication mechanism, and a consumer migration table**
  - Where in the plan: "Attention signalling versus notification history" — the two-index split and the predicate `!(suppressed && !flagged)`.
  - Problem: Verified — `hasUnreadNotification(forTabId:surfaceId:)` currently serves two incompatible classes of work: the exact-surface waiting projection (`Sources/WorkspaceContentView.swift:92`, `Sources/Workspace.swift:6744`) and focus-driven mark-read (`Sources/TabManager.swift:3421`, `:3433`, `:3615`). Silently giving it signal semantics fixes suppression rendering and breaks read-marking for suppressed surfaces; leaving it raw leaks suppression into waiting visuals. Separately, `NotificationIndexes` is keyed **by tab** (`unreadCountByTabId`, `TerminalNotificationStore.swift:640`) while suppression is **per surface** and `TerminalNotification.surfaceId` is optional — the plan never states the aggregation rule for a tab holding one suppressed and one ordinary surface. And `notifications` is `@Published` with index rebuild in its `didSet`; the plan forbids rewriting the array to force `didSet` but names no replacement invalidation signal, so a suppression change will not invalidate views.
  - Revision: (a) Name three projections explicitly — raw unread/history, exact-surface unread used to derive true lifecycle, and routine waiting demand — with distinct API names (e.g. `hasRawUnread`, `hasLifecycleUnread`, `hasRoutineWaitingDemand`); do not silently change the meaning of any existing method. (b) Add a checked-in consumer table mapping every current call site to one of the three, including `ContentView`, `WorkspaceContentView`, `TabManager` focus/read paths, `c11App`, `UpdateTitlebarAccessory`, `AppDelegate`, and `NotificationMenuSnapshotBuilder`. (c) Publish an explicit signal snapshot or monotonic `signalRevision` as part of the attention commit; no scattered `objectWillChange.send()`. (d) State the tab-level aggregation rule. (e) Name the single function that owns index rebuild and waiting-edge emission, so notification arrival and attention mutation cannot both rebuild-and-emit (double-emit / lost-edge race). (f) State whether a surface that is both flagged and truly waiting increments both the Flagged Agents count and the Waiting Agent count, and which projection feeds each.
  - Sources: Standard/Codex (blocking gap 2, Q8/Q9/Q10), Adversarial/Codex (executive summary, blind spot 1, Q1/Q2/Q3), Adversarial/Claude (A6, Q9, Q10), Standard/Claude (architectural assessment).

- **B5: The binding spec, the staged skill section, and the task description still contradict the plan's own resolved Phase 3 decision**
  - Where in the plan: "Operator Phase 3 decision — resolved" (direct flag raise on a suppressed surface **does** deliver) versus Phase 6 step 4 ("Copy the staged section from `docs/c11-attention-model-skill-section.md` into `skills/c11/SKILL.md` **exactly**, adjusting only if a shipped *command contract* necessarily changed").
  - Problem: The staged skill section states suppression excludes system notifications, and `docs/c11-flagged-agent-plan.md` says "Suppressed surfaces deliver no system notification, by definition." Neither statement is a command contract, so Phase 6's own escape clause does not authorize fixing them — the plan as written instructs copying a now-false paragraph into the live skill. The plan defers the spec amendment to "in this PR" and never mentions the staged skill or the task description at all. This is the feature's headline trust promise; three reviewers independently called it out as a contract inconsistency rather than a late implementation detail.
  - Revision: Add an explicit pre-implementation contract-reconciliation step (Phase 0) that amends `docs/c11-flagged-agent-plan.md`, `docs/c11-attention-model-skill-section.md`, and the Lattice task description to the narrowed rule — suppression bars routine waiting-derived delivery; an explicit flag raise is an escalation that may deliver externally — *before* Phase 1 begins. Reword Phase 6 step 4 so the "copy exactly" rule permits (and requires) carrying that reconciliation through.
  - Sources: Standard/Codex (blocking gap 1, Q4/Q5), Adversarial/Codex (blocker 1, "Direct flag delivery piercing suppression", Q4/Q5), Evolutionary/Codex (§3, Phase -1), Adversarial/Claude (Disruption 3).

- **B6: The hard latency gate has no instrument, an unreachable test configuration, and a baseline that charges this ticket for C11-183**
  - Where in the plan: "Fleet-scale latency protocol" — "Capture p50/p95 keystroke-to-paint timing", "at least 20 active agent surfaces so 40+ marks exist", "feature-on p95 delta versus the static baseline is <= 1 ms", and the three-rung fallback ladder.
  - Problem: Three reviewers searched and found no keystroke-to-paint harness in the repository. The only instrument, `CmuxTypingTiming` (`Sources/AppDelegate.swift:104`), is DEBUG-only, threshold-gated at 6 ms / 1 ms so sub-threshold samples are discarded (p50 is arithmetically underivable), and measures event delay and handler duration rather than keystroke-to-paint. Building the harness is unscoped work hidden inside a validation step, and 1 ms is plausibly below the run-to-run noise floor of a 20-agent machine. Separately, the "40+ concurrently animating marks" configuration contradicts the plan's own correctness requirement that off-screen, collapsed, unselected-workspace, and background marks unsubscribe — the worst case the gate claims to measure is unreachable by construction. And the static baseline charges C11-184 for C11-183's shipped, separately-decided base motion; ladder rungs 1 and 2 ("disable stepped fill by default", "ship base marks static") are C11-183 reversals wearing a C11-184 label.
  - Revision: Pick one of two paths and write it down. (i) Scope the harness as a named deliverable with its own owned file and phase, stating the probe, clock, sample count, warm-up, ordering/randomization, and output artifact; or (ii) restate the gate in proxies that can actually be measured — `BonsplitDebugCounters` body-evaluation counts during a typing burst, shared-clock subscriber count, sustained-typing CPU — plus a subjective typing pass. Independently of that choice: correct the baseline to HEAD-with-base-motion-at-its-shipped-default versus the same build with flags, at a realistic flagged population; restrict the fallback ladder to the one rung inside this ticket ("flags ship static violet") and record any base-motion observation as input to a C11-183 follow-up rather than a C11-184 rung; reconcile the 40-mark configuration against the unsubscribe rules; and decide in advance, in writing, which rung ships if the gate cannot be run at all.
  - Sources: Adversarial/Claude (executive summary, A1/A2, Q1/Q2/Q3/Q23), Standard/Claude (Bet 3, G6, Q8), Adversarial/Codex (blind spot 9, Q22), Evolutionary/Claude (§7 — the baseline correction and ladder-scope point is his).

- **B7: The CI-only test strategy relies on gates this repository does not have**
  - Where in the plan: "Compile and CI gates" ("Push and require the repository PR checks, including their real test actions. CI is the sole test executor for this ticket", "Trigger the GitHub E2E workflow") and the test-ownership table assigning host-bound and Bonsplit coverage to PR CI.
  - Problem: All three claims verified. `.github/workflows/ci.yml:215` marks the host-bound `c11Tests` job `continue-on-error: true` — it is advisory and cannot fail a PR. `ci.yml` never invokes a Bonsplit test target. `.github/workflows/test-e2e.yml` does not exist on this branch (removed in `7cbc27d31`), and `scripts/run-e2e.sh:11` still targets `manaflow-ai/cmux`, an upstream repository this project must never write to. A plan that forbids all local test actions and routes every assertion to absent or advisory remote gates can merge fully green with all portal-focus, notification-delivery, and package-animation assertions failing.
  - Revision: Fix the plan's validation contract to match reality. Either add a dedicated non-advisory CI job for the new host-bound slices, or move that coverage into `c11LogicTests` where CI hard-fails. Add a Bonsplit test job, or move the generic mark-presentation coverage into a target CI actually runs. Delete the "Trigger the GitHub E2E workflow" step or replace it with a named, fork-owned workflow that exists; do not leave an instruction pointing at `manaflow-ai/cmux`.
  - Sources: Adversarial/Codex (failure mode 3, assumption audit, Disruption 3, Q20/Q21). Single-reviewer but every claim independently verified against the repository.

- **B8: `syncSurfaceTabActivityStateForPanel`'s early return will silently swallow flag presentation changes**
  - Where in the plan: `Sources/Workspace.swift` listed under owned seams as "lifecycle/presentation sync"; tagged-validation scenario 2 ("A flag raised mid-working: both marks snap violet").
  - Problem: Verified at `Sources/Workspace.swift:6750-6751` — `guard existing.activityState != activityState || existing.showsNotificationBadge != shouldShowLegacyUnread else { return }`. A flag raised on a **working** surface changes neither term, so `updateTab` is never called and the surface tab never turns violet. The plan's own headline validation scenario fails on first run.
  - Revision: Name this guard explicitly as a change site. Require it to compare the full presentation value (activity state plus the new generic presentation payload plus badge), not just `activityState`, and add a named regression test asserting that a flag raise on a working surface propagates to the Bonsplit tab.
  - Sources: Standard/Claude (G1). Single-reviewer but the cited code is exact and the failure is deterministic.

---

### Important (revise before implementation starts)

- **I1: `flag.list`, the Flagged Agents row, and `WorkspacePulseSummary.flaggedCount` have three different implied scopes, and multi-window is absent**
  - Where in the plan: "The current Waiting Agent footer is app/window-global… The Flagged Agents row follows that existing scope; this does not add the explicitly out-of-scope cross-workspace dashboard"; plus `WorkspacePulseSummary.flaggedCount` (per-workspace) and `flag.list` (scope never stated).
  - Problem: "App/window-global" is two different things. `TerminalNotificationStore.shared` is process-global, so every window would show the same flagged count and could jump into another window. Meanwhile the per-workspace `flaggedCount` means two different flag counts can be on screen simultaneously with no stated relationship. Adversarial/Codex additionally reads the binding spec as keeping c11 chrome workspace-local, making "follows the existing scope" a real product-scope expansion rather than an inheritance.
  - Revision: State one scope explicitly for each of `flag.list`, the Flagged Agents row count, and `WorkspacePulseSummary.flaggedCount`, and state how they relate when they differ. Make the scope an explicit query parameter internally (active window / workspaces owned by that window / process-wide) even if v1 exposes only one. Add tests for two windows with flags in only one, closing one window, and a flag-notification click whose target window is not current. If the answer is app-global, say plainly that the plan amends the binding spec's workspace-local UI framing rather than inheriting it.
  - Sources: Standard/Claude (G5, Q14, Q16), Standard/Codex (significant gaps, Q14), Adversarial/Codex (blind spot 5, "App-global flagged row", Q13/Q14), Adversarial/Claude (B8, Q16), Evolutionary/Codex (§5, Q6).

- **I2: The direct flag notification has no identity or lifecycle**
  - Where in the plan: "In-surface banner and system notification" — "repeated identical raise is not redelivered", and mutation semantics item 1's "one updated direct notification".
  - Problem: "Updated rather than duplicated" requires a stable OS notification identifier, which the plan never defines. Nor does it say what happens to pending/delivered notifications on lower, close, prune, or suppress; whether a new epoch gets a new identifier; or how a click resolves after the surface has been transferred or closed. Separately, `NotificationSoundSettings.runCustomCommand` runs after scheduling and cannot be retracted — suppression's promise must be stated temporally.
  - Revision: Specify a stable identifier keyed on surface plus flag epoch. A reason revision replaces that request rather than adding one; lower/close/prune removes pending and (decide explicitly) delivered requests; a new epoch takes a new identifier. Define click resolution by stable surface ID after transfer, and fail-closed after close. State plainly that suppression prevents future routine delivery and retracts removable requests but cannot undo an already-executed custom command.
  - Sources: Standard/Codex (blocking gap 5, Q16/Q17/Q18), Standard/Gemini (weakness 3, Q2), Adversarial/Codex (blind spot 7, Q16/Q17), Evolutionary/Codex (§6, suggestion 4, Q3).

- **I3: `by: operator | agent` is caller-settable on an unauthenticated local socket, and the plan leans on it as trust**
  - Where in the plan: "agent CLI lower/suppress/unsuppress defaults to `agent`, with an explicit socket field for trusted operator-originated actions."
  - Problem: The c11 socket has no per-caller authentication; agents and the operator's shell run as the same user and reach the same socket. Any agent can claim `operator`. The spec's entire justification for `by` is that a dismissed agent can distinguish "seen and deferred" from "nobody looked" — a field whose only value is trust, with a caller-settable value, will silently lie.
  - Revision: Derive `by: operator` from in-app/AppKit call paths only (the banner X, menu actions). Socket and CLI mutations are recorded as claimed attribution or default to `agent`. Document `by` as descriptive provenance, not an authorization boundary, and adjust any skill text that implies otherwise. If genuine operator CLI provenance is needed, define a real capability rather than a string field.
  - Sources: Standard/Codex (significant gaps, Q7), Adversarial/Claude (A4, Q12), Adversarial/Codex (assumption audit, "Exposing claimed operator origin", Q12), Evolutionary/Codex (§4, suggestion 6, Q5).

- **I4: Launch-time flags self-notify the operator, and "launch modifiers are operator-originated" is wrong for the primary use case**
  - Where in the plan: "Launch-time modifiers are operator-originated"; Phase 2 items 4–5; mutation semantics item 1 (raise unconditionally reaches the direct-delivery seam).
  - Problem: As written, `c11 launch-agent --flag "watch this migration"` delivers a system notification to the operator roughly 200 ms after they pressed Enter, announcing a flag they just raised on a surface they are looking at. Separately, the headline orchestrator/subagent shape is an *agent* running `launch-agent --suppressed` for its children — labelling every launch-time modifier operator-originated mis-attributes exactly the case the feature was designed for.
  - Revision: State that operator-originated raises do not fire direct system delivery, kept as a condition independent of the suppressed-piercing branch at the same call site (two independent conditions, not one tangled predicate). Derive launch-time `by` from the launching context (operator shell versus agent surface) rather than hardcoding `operator`. Also state whether a mission-scoped launch flag stays raised through ordinary completion.
  - Sources: Standard/Claude (G2, Q4), Standard/Codex (intent drift, Q2/Q3), Adversarial/Codex (assumption audit, Q11).

- **I5: "Extend the resolver **or** introduce a sibling reducer" must become one reducer, and the existing duplicate must be deleted**
  - Where in the plan: "Extend `SurfaceTabActivityResolver` (or introduce a sibling pure reducer)"; risk register entry "Spec precedence implemented differently in two renderers."
  - Problem: Verified — the plan's headline reduction is *already* implemented twice at HEAD: `Sources/Sidebar/SidebarActivityProjector.swift:55` and `Sources/ContentView.swift:11436` each compute `suppressed && !flagged && state == .waiting ? .idle : state` independently. The plan adds `AttentionModel.swift` and `SurfaceLivenessDeriver.swift` as further consumers and never says the duplicate is deleted. The named risk is not mitigated; it is pre-existing and about to be doubled.
  - Revision: Choose extension over a sibling. Specify exactly one function mapping (lifecycle, unread, flag, suppression) to presented state, and add an explicit phase task deleting the duplicate at `ContentView.swift:11436` so both `WorkspacePulseAgent.presentedState` and the Bonsplit tab path call the single reducer.
  - Sources: Adversarial/Claude (failure pattern 5, Q25), Standard/Claude (architectural assessment, Q11), Standard/Codex (refinement 3).

- **I6: Surface close / detach / prune semantics for an active flag are undefined, and the prune path is fire-and-forget**
  - Where in the plan: "Snapshot restore, launch stamping, detach/transfer, close, and prune also enter through explicit service hooks."
  - Problem: Verified — `SurfaceMetadataStore.removeSurface` uses `queue.async` (`:579`) while writes use `queue.sync`, so closing a flagged surface removes its metadata asynchronously relative to any UI update, opening a visible stale-count window. The plan also never says whether closing a flagged surface emits `flag.lowered` (and with what `by`), which an Overwatch consumer tracking open flags needs, nor whether a detached flagged surface preserves its reason and epoch while changing workspace ownership without briefly leaving a stale queue entry.
  - Revision: Add an operation-effects table covering live raise, reason revision, restore, launch stamp, transfer/detach, close, prune, keyed clear, and clear-all — stating for each what is emitted, what is delivered, and what the cache does. Explicitly: restore hydrates without `flag.raised` and without external delivery; transfer preserves epoch and reason; close/prune removes the cache entry without pretending an operator or agent lowered it (or, if it does emit, say so and name the actor). Address the `queue.async` stale-count window.
  - Sources: Adversarial/Claude (B5), Standard/Claude (Q15), Adversarial/Codex (blind spot 2, Q8), Standard/Codex (significant gaps — transfer hooks).

- **I7: The restore path has no validation seam at all**
  - Where in the plan: "canonical state round-trips through snapshot restore; invalid/blank/multiline/oversize reasons and non-Boolean suppression fail before mutation."
  - Problem: Verified at `Sources/SurfaceMetadataStore.swift:566-573` — `restoreFromSnapshot` assigns `metadata[...] = values` and `sources[...] = sources` wholesale with zero validation; the only key special-cased is `flash_state`, and that happens at the call site. A corrupted or hand-edited session snapshot can inject a multi-kilobyte, multi-line `flag` value that bypasses every validator the plan builds and is then rendered in a banner floating over terminal pixels.
  - Revision: Add validation on the restore path specifically (the function currently has nowhere to hook — that seam must be built), truncate defensively at the banner, and require that malformed attention metadata fails closed without deleting unrelated metadata. Add a test with a hostile snapshot.
  - Sources: Adversarial/Claude (B6, Q13), Adversarial/Codex (blind spot 2 — "restore of malformed or version-skewed metadata fails closed").

- **I8: `flaggedCount` and the navigable flag set can disagree**
  - Where in the plan: "Skip stale/unopenable surfaces and try the next flag" versus `WorkspacePulseSummary.flaggedCount` and the row's count badge.
  - Problem: Navigation skips stale/unopenable flags; nothing says the count excludes them. A row reading "3 flagged" that jumps to only one is a correctness bug already written into the plan, and there is no acceptance item for it.
  - Revision: State the invariant that the displayed flagged count equals the navigable flag set, add it to the acceptance checklist, and add a test with at least one stale/unopenable flagged surface.
  - Sources: Adversarial/Claude (B4, Q8), Standard/Claude (G9 — related, on restored cold flagged surfaces).

- **I9: `flag.raised` cannot be consumed idempotently — no epoch, `raised_at`, or revision marker**
  - Where in the plan: mutation semantics item 1 ("emits one new `flag.raised` event") plus the event taxonomy `flag.raised payload: { reason }`.
  - Problem: The plan's internal semantics are correct (revision preserves the epoch) but nothing on the wire says so. A consumer tailing the events stream — which is the plan's entire stated Overwatch integration and its answer to "no cross-workspace dashboard" — sees two `flag.raised` events for one surface and cannot tell that the queue age did not reset. A cron escalation firing on "flag up for an hour" is reset by every revision. The event envelope has a published JSON schema and a `skills/c11/references/events.md` entry, so this is a v1 external-contract defect that is expensive to fix later.
  - Revision: Settle the payload before any handler code. Add `raised_at` plus a revision marker (or a distinct `flag.updated` type) to `flag.raised`, and update `spec/event-envelope.v1.schema.json` and `skills/c11/references/events.md` in the same commit. While the schema is open, also add `by` to `flag.raised` — three of the four attention events carry provenance and the spec insists flags arrive from both sides, so the omission looks like an oversight rather than a decision.
  - Sources: Adversarial/Codex (blind spot 3, Q18), Evolutionary/Claude (§3, suggestion 1), Evolutionary/Codex (suggestion 14), Standard/Claude (G3, Q5 — the `by` half).

- **I10: The required accessibility output cannot be produced by the proposed renderer payloads, and Bonsplit's own locale catalogs are outside the Phase 6 translator scope**
  - Where in the plan: Phase 4 item 5 ("Update accessibility values so flag reason/flag state are announced") versus the data model (`WorkspacePulseAgent` carries booleans; the proposed Bonsplit presentation carries color, motion, and alternate core color) and Phase 6 item 2 (translator scope is `Resources/Localizable.xcstrings` only).
  - Problem: Neither renderer payload carries the flag reason, so the announcement the plan requires is not constructible. Separately, Bonsplit owns seven `Localizable.strings` catalogs under `vendor/bonsplit/Sources/Bonsplit/Resources/<locale>.lproj/` and resolves tab accessibility strings internally — the plan's owned-file list and translator scope cover neither.
  - Revision: Carry a normalized reason (or a fully-formed accessibility string) into the sidebar agent presentation, and add a generic host-supplied accessibility value/help override to the Bonsplit presentation object — keeping the public Bonsplit vocabulary generic (no `flagReason` naming). Choose explicitly between injecting already-localized accessibility text through that object versus adding and translating generic keys in all seven Bonsplit catalogs, and reflect the choice in Phase 6's scope. Also decide whether the reason is announced on marks at all or whether "Flagged" suffices there with the reason living on the banner.
  - Sources: Standard/Codex (blocking gap 4, Q12), Adversarial/Codex (blind spot 6, Q19).

- **I11: "Dominant attention precedence is flagged > waiting > …" has no type that can express it**
  - Where in the plan: "Add `WorkspacePulseSummary.flaggedCount`; dominant attention precedence is flagged > waiting > working > idle > cold without adding a `WorkspacePulseState` case."
  - Problem: `WorkspacePulseSummary.dominant` returns `WorkspacePulseState`. It cannot return "flagged" without a separate dominance/priority type, a `(state, flagged)` presentation value, or a `dominantAgent` plus derived presentation. `flaggedCount` alone does not define what `dominant` returns for a flagged-working agent, so the sentence is not an executable contract.
  - Revision: Choose one of the three shapes, name it in the plan, and identify its consumers.
  - Sources: Standard/Codex (blocking gap 4, Q11).

---

### Straightforward mediums

- **M1: `flag.list` has no CLI counterpart**
  - Where in the plan: Phase 2 adds socket methods `flag.raise / lower / list / suppress / unsuppress` and CLI commands for four of the five.
  - Problem: An orchestrator that dispatched a fleet has a push event stream and a socket method it cannot reach from the shell. The staged skill section documents no read command either. The plan's "no cross-workspace dashboard" non-goal excludes UI, not a read command.
  - Revision: Add `c11 flags [--json]` in Phase 2, a line in the staged skill section, and a behavior test asserting deterministic oldest-first output containing refs, reason, timestamp, and suppression.
  - Sources: Standard/Claude (G5, Q7).

- **M2: Suppression has no bulk read, in the feature's own headline use case**
  - Where in the plan: Phase 2 item 6 ("Return attention fields in machine-readable launch/list results") — one line, no acceptance item, no test.
  - Problem: Suppression is by design completely invisible (no tint, dim, badge, or label) and both the spec and the mark-vocabulary doc name "orchestrator with a suppressed subtree" as its primary shape. With no enumeration, an orchestrator with thirty suppressed children can only issue thirty `get-metadata` calls, and forgotten suppressions silently make the sidebar a less truthful picture of the fleet with no mechanism reversing it.
  - Revision: Promote suppression enumeration to a first-class, tested output — either extend `flag.list` into an attention list returning active flags *and* suppressed surfaces (with refs and `suppressed_at`), or make attention fields on `surface.list` an acceptance-checklist item with a test. Same handler, same commit boundary.
  - Sources: Adversarial/Claude (B2, Q5), Evolutionary/Claude (§5, suggestion 2), Adversarial/Gemini (blind spots), Evolutionary/Gemini (concrete suggestions).

- **M3: Reason validation is underspecified and duplicated across ingresses**
  - Where in the plan: "`MetadataKey.flag`: non-empty, trimmed, single-line string; cap at 256 characters."
  - Problem: "Single-line" does not say whether all Unicode newline scalars (CR, LS, PS, NEL) and control characters are rejected or only LF; "256 characters" does not say graphemes versus UTF-8 bytes, nor whether the cap is measured before or after trimming and normalization. Validation would otherwise be reproduced at the socket family, generic metadata path, launch flags, and restore. An over-cap rejection also strands an agent that is already blocked if the error does not state the cap.
  - Revision: Introduce one `FlagReason` parser/normalizer used by every ingress. Specify newline and control-character treatment, grapheme-versus-byte counting, and trim/normalize ordering. Ensure the `invalid_params` error message states the cap so a blocked agent can retry successfully.
  - Sources: Standard/Codex (significant gaps, Q22), Evolutionary/Codex (§4, suggestion 7), Standard/Claude (G10 — the error-message half only; reject-versus-truncate is deferred to S).

- **M4: Flag reason text has no privacy statement**
  - Where in the plan: absent — the reason is persisted in session snapshots, emitted into the event log, rendered over terminal pixels, and placed into system notifications.
  - Problem: A 256-character cap is not a privacy policy. Agent-authored reasons can carry secrets or customer data into lock-screen-capable notification previews, the durable event log, and custom notification commands.
  - Revision: Add a short statement to the plan covering guidance on secrets/customer data in reasons, notification-preview expectations, and whether event-log and snapshot retention of reason text is acceptable. Exclude or redact reason text from any aggregate analysis.
  - Sources: Adversarial/Codex (blind spot 8, Q23), Evolutionary/Codex (§4, Q8).

- **M5: The banner's interactive control is invisible to the existing focus-classification predicate**
  - Where in the plan: "X calls `lower(by: .operator)` and restores terminal focus without synthesizing terminal input"; "do not touch `TerminalSurface.forceRefresh()` or `WindowTerminalHostView.hitTest()`."
  - Problem: Verified — `isSearchOverlayOrDescendant` (`Sources/GhosttyTerminalView.swift:8809`) walks the responder chain testing for `NSHostingView<SurfaceSearchOverlay>` and string-matching `"BrowserSearchOverlay"`, and it gates focus-clearing at `:8597` and `:8640`. A third interactive overlay must either be known to that predicate or be guaranteed never to become first responder.
  - Revision: Name that function in the plan. Decide and state whether the banner X can become first responder; if yes, extend the predicate; if no, state it as a design constraint and test it.
  - Sources: Adversarial/Claude (A7, Q15).

- **M6: Localization is scheduled last but the strings are written in Phases 2, 4, and 5**
  - Where in the plan: Phase 6 item 1 ("Stabilize English `String(localized:defaultValue:)` keys first") — scheduled after CLI help (Phase 2), the Flagged Agents row (Phase 4), and the banner (Phase 5).
  - Problem: In practice those strings get written as bare literals when needed, and Phase 6 becomes a hunt for them rather than a translation pass — the exact failure `CLAUDE.md` warns about. Also, the staged skill text asserts that a flagged-waiting mark "strobes", which the Phase 4 motion fallback rung ("flags ship static violet") would falsify without any command-contract change.
  - Revision: Require localized keys at the moment each string is written in Phases 2, 4, and 5; Phase 6 becomes translation-only. Add one Phase 6 reconciliation step: if the motion fallback rung was taken, update the strobe clause in both `docs/c11-attention-model-skill-section.md` and `skills/c11/SKILL.md` before the translator stage runs.
  - Sources: Adversarial/Claude (C6), Evolutionary/Claude (§9, suggestion 10).

- **M7: "Persisted" is claimed but the store is in-memory behind an 8-second autosave**
  - Where in the plan: "Both are written at `.explicit`, survive the existing session snapshot/autosave path"; "A mutating socket response is sent only after that whole commit is observable."
  - Problem: An OK response means in-memory observable, not crash-durable — the snapshot lands on the autosave cadence. For a sticky escalation primitive the operator will trust more than ordinary status metadata, a crash inside the autosave window silently loses the flag while every unit test passes.
  - Revision: State the durability semantics explicitly (response means committed and observable; durability follows the existing autosave cadence), and decide whether an attention mutation forces a snapshot write. Add restart coverage to the tagged validation flow: quit and resume with an active flag, a revised reason, and a suppressed unread record.
  - Sources: Adversarial/Codex (failure mode 4, Q7), Standard/Codex (significant gaps — quit/resume verification missing from the tagged flow).

- **M8: Unsuppress replay behavior is undefined for external delivery**
  - Where in the plan: mutation semantics item 4 ("An existing unread record becomes signal-eligible again and may create the correct 0->1 waiting edge; it does not manufacture a second record").
  - Problem: The plan covers in-app demand but never says whether unsuppressing an old unread record retroactively delivers the desktop notification that was intentionally suppressed at creation time. "Eligible now" silently meaning "deliver externally now" is a plausible and unpleasant implementation.
  - Revision: State that unsuppressing restores in-app demand only and does not replay desktop delivery, and add a test.
  - Sources: Evolutionary/Codex (§3, suggestion 5, Q4), Standard/Codex (raw-versus-signal consumer contract).

- **M9: The second `WorkspacePulseProjector.project` overload is unaddressed**
  - Where in the plan: owned seams list `Sources/Sidebar/SidebarActivityProjector.swift` without mentioning the overload.
  - Problem: `SidebarActivityProjector.swift` carries a second `project(hasWorkspaceDemand:surfaceStates:…)` overload taking bare `[WorkspacePulseState]` with no agent records and therefore no modifiers. If it is live, it is a path where flags and suppression silently do not apply.
  - Revision: State whether it is dead, needs the modifier fields, or is intentionally modifier-free.
  - Sources: Standard/Claude (G8, Q12).

- **M10: The controlled-timestamp test has no injection seam**
  - Where in the plan: tagged-validation scenario 9 ("Two flags with controlled timestamps") and the raise timestamp defined as the metadata source timestamp.
  - Problem: With no stated injection seam, "two flags with controlled timestamps" degrades into "raise one, sleep, raise another," which is flaky — and this is CI-only coverage, so flakes are expensive.
  - Revision: State whether the pure selector takes timestamps as inputs (which the plan's purity claim implies) or the service takes an injectable clock. Also add debug-only shared-clock subscriber-count and body-churn seams, since the latency protocol asserts on both.
  - Sources: Standard/Claude (G7, Q9), Evolutionary/Codex (suggestion 13).

- **M11: No rebase cadence and no duration estimate anywhere**
  - Where in the plan: absent across all seven phases.
  - Problem: The branch spans the four largest files in a repository whose default workflow runs parallel delegators against `main`. With no cadence and no estimate there is no point at which anyone can tell the ticket is running long, and every rebase across those files risks silently reverting an attention-path edit.
  - Revision: Add a stated rebase cadence against `main` and a rough duration per phase.
  - Sources: Adversarial/Claude (B9, failure pattern 1, Q19/Q22).

---

### Evolutionary clear wins

- **EW1: Add `resolution` to `flag.lowered` while the event schema is still unpublished**
  - Where in the plan: event taxonomy `flag.lowered payload: { by: "operator" | "agent" }`.
  - Problem: `by` is the agent's only outcome signal, and the staged skill instructs agents to make a real decision on it ("Re-raise only if the blocker still stands and you can say why the deferral does not"). That decision is not computable from one bit: an agent that flagged well and one that flagged badly receive an identical signal, which breaks the feature's stated self-regulation loop before it starts.
  - Revision: Add one optional enum field — `resolution: "deferred" | "resolved"` at minimum, set by which affordance was used (banner X versus agent lower), with room for `"answered"` later. Land it in the same commit as the `flag.raised` payload work in I9, including `spec/event-envelope.v1.schema.json` and `skills/c11/references/events.md`. One enum now; a schema amendment plus CLI, socket, skill, and six locales later.
  - Sources: Evolutionary/Claude (§2, suggestion 1, "The Flywheel"), Evolutionary/Gemini (concrete suggestion 2), Evolutionary/Codex ("Attention receipts").

---

## Surface to user (do not apply silently)

- **S1: Split the ticket into two or three PRs**
  - Why deferred: disagreement
  - Summary: Three reviewers pushed hard for a split along the plan's own commit-unit list — Standard/Claude proposed three PRs (model+primitives+events+CLI+skill / signal+navigation / renderers+banner+localization+latency), Adversarial/Claude and Evolutionary/Claude both proposed two at the Phase 3/4 boundary. Their shared argument: Phases 0–3 are a complete, headless, externally consumable product with zero rendering risk and zero submodule exposure, and a failed latency gate in the visual half would otherwise hold the model, primitives, and events hostage on a branch touching the four largest files in the repo. Evolutionary/Claude adds that PR 1's live event stream becomes PR 2's validation input. Standard/Codex explicitly disagrees: one PR is defensible given the draft-PR discipline and coherent commit units, and a split creates an awkward intermediate state where canonical modifiers exist without a trustworthy operator surface. The only stated coupling is the skill text asserting visual behavior, which Evolutionary/Claude says could be resolved by softening two clauses. This is a sequencing call for the plan author and operator, and it interacts with B6 and B7.
  - Sources: Standard/Claude (readiness verdict, blocking 1, Q1), Adversarial/Claude (C1, Q18), Evolutionary/Claude (§Sequencing, suggestion 3); dissent from Standard/Codex ("Is This the Move?").

- **S2: Color-blind operators cannot detect a flag in either mark renderer**
  - Why deferred: design-needed
  - Summary: C11-183's justification was explicitly accessibility — shape carries lifecycle so "color is thereby free for the flagged modifier." The flagged modifier then spends *only* color. For a protanope or deuteranope, flagged-idle and ordinary-idle are the same shape in near-identical values. Motion partially covers it, but the plan makes Reduce Motion a hard override on all flag motion, so Reduce Motion plus color-vision deficiency makes flagged undetectable in both mark renderers — the fleet-scan channel that is the feature's entire purpose. Both binding docs note that opacity is a completely free, unspent channel. Adversarial/Claude calls this the most serious gap in the plan and asks for one of: spend opacity, add a second shape channel, or write down the accepted cost. Every other accessibility item in the plan is VoiceOver or Reduce Motion.
  - Sources: Adversarial/Claude (B1, Q6, "Hindsight Preview").

- **S3: ⌥V is a latch, not a queue, and its recency character inverts**
  - Why deferred: design-needed
  - Summary: Two related challenges. Adversarial/Codex: the selector always chooses the oldest active flag and opening does not lower it, so repeated ⌥V presses return to the same surface forever — the operator cannot survey the second flag without dismissing the first, even if the first needs a decision they are not ready to make. Proposed remedies include a per-invocation cycle cursor or a deliberate acceptance of the starvation. Adversarial/Claude: ⌥V today goes to the *latest* unread, so its destination is contextually close; oldest-first plus a global flag queue means the destination is by construction the least recent thing and can yank the operator out of the workspace they are actively working in. He asks that alternatives (latest-first for flags, oldest-first within the current workspace before crossing, a soft current-workspace preference) be named and rejected deliberately rather than by default. This is the most-used key in the sidebar cluster.
  - Sources: Adversarial/Codex (failure mode 5, "Oldest flag always wins", Q15), Adversarial/Claude (C3, Q17).

- **S4: A mission-scoped flag means a permanent banner over live terminal pixels**
  - Why deferred: design-needed
  - Summary: The spec permits flagging at dispatch (a critical mission the operator intends to watch, "violet for its lifetime") and `launch-agent --flag` is a Phase 2 deliverable. The banner mounts at the top edge over terminal pixels and its only control lowers the flag. So an operator who flags a mission at dispatch gets a banner permanently obscuring the top of that surface's output for the mission's entire life, and the only way to hide it destroys the intent the flag was expressing. Evolutionary/Claude proposes a collapse-without-lower chevron (his preference), auto-collapse after first view, or launch-time flags rendering collapsed by default, and notes this must be decided in the plan rather than Phase 5 because it affects the banner state model, whether collapsed state persists, two localized strings, and the accessibility contract.
  - Sources: Evolutionary/Claude (§8, suggestion 5, Q5); related concern from Adversarial/Gemini (banner obscures top-line terminal content).

- **S5: The `C11-184` short ID is already spent on a different, shipped feature**
  - Why deferred: author-intent-needed
  - Summary: Verified — commit `46566ed14` ("Plan C11-184 surface tab agent states") assigned `C11-184` to Lattice task `task_01KY3NSPW23B9ED5S0RQCZK2C8`, which shipped as PR #360 (`dbdd75ec5`, "Show agent state on surface tabs"). The current task `task_01KYMTXQVWCXCF0TGN5ZWG341E` also carries `"short_id": "C11-184"`. Adversarial/Codex argues this will poison search, branches, worktrees, review artifacts, release notes, and future incident reports ("C11-184 regression" would be ambiguous), and asks for a rename to an unused ID or an explicitly recorded alias before any commits use the duplicate. Renumbering a live Lattice ticket mid-flight is an operator call.
  - Sources: Adversarial/Codex (blind spot 10, uncomfortable truth 8, Q24).

- **S6: No kill switch or rollback path for a change to the app's default attention behavior**
  - Why deferred: design-needed
  - Summary: This feature changes waiting counts, the ⌥V destination, both mark renderers, the sidebar, and external notification delivery. The regressions that matter (a lost `waiting.entered` edge, a double-counted flag, ⌥V going somewhere wrong) are invisible until the operator misses something — the worst detection profile — and the only offered remedy is reverting a seven-phase branch. Adversarial/Claude proposes a defaults-backed switch forcing signal-eligibility to equal raw eligibility, citing the existing `Static marks` user default as precedent. Evolutionary/Claude separately suggests shipping the suppressed-piercing delivery branch as a `UserDefaults` key so the question stays empirically revisable.
  - Sources: Adversarial/Claude (B7, Q20), Evolutionary/Claude (suggestion 9).

- **S7: No efficacy instrumentation — the feature is unfalsifiable as planned**
  - Why deferred: scope-creep / author-intent-needed
  - Summary: The motivation makes a falsifiable claim (scan cost grows linearly with fleet size; flags fix it) and the plan ships four event types that would make measurement trivial, then never proposes reading them. Nothing counts flags raised per week, flag lifetime before lower, `by` distribution, or the fraction of agents that ever flag against the spec's stated nine-in-ten target. If agents start flagging routinely the tier is dead, and there will be no data to prove it. Adversarial/Claude asks for a minimal read off the existing `c11 events tail`; Evolutionary/Claude and Evolutionary/Codex both frame the same point as the flywheel that closes the agent-calibration loop.
  - Sources: Adversarial/Claude (B3, Q21), Evolutionary/Claude (§"What It Unlocks" 6, Q8), Evolutionary/Codex ("Attention-quality analytics", Q12).

- **S8: Neither modifier has a lifecycle end, and suppression is the dangerous one**
  - Why deferred: design-needed (adjacent to explicit non-goals)
  - Summary: Both modifiers are sticky, survive relaunch, have no expiry, no bulk clear, and no auto-lower (all explicit non-goals). Two accumulation failures follow. A surface suppressed for an overnight sweep is still suppressed the next morning when the operator starts using it interactively, with no indicator to notice it by. Stale flags accumulate, and once the Flagged Agents row is permanently non-zero its entire design justification ("zero flags, zero footprint; a new element appearing is a stronger signal than an existing button changing color") is destroyed. Proposed remedies span time-bound suppression (`suppress --until 1h`), a `lower-flag --all`, and cold-flag deprioritization in the queue. Adversarial/Gemini's stress test is the sharpest version: suppressed agents that die silently read as idle and the operator assumes success.
  - Sources: Adversarial/Claude (B4, Q7, "Hindsight Preview"), Adversarial/Gemini (blind spots, reality stress test, Q4), Evolutionary/Gemini (ephemeral suppression), Standard/Claude (G9 — restored cold flagged surfaces holding the queue head).

- **S9: Challenges to three explicit non-goals**
  - Why deferred: author-intent-needed (each is a stated non-goal in the plan)
  - Summary: (a) *Auto-lower on terminal input* — Adversarial/Gemini argues terminal input is the literal definition of a human intervening, so forcing an additional X click is double work. (b) *Rate limiting* — Standard/Gemini, Adversarial/Gemini, and Evolutionary/Gemini all raise flag-storm and notification-spam risk (a malfunctioning agent varying its reason string, or fifty agents flagging on one outage); note that the stable-identifier work in I2 mitigates the revision case but not the storm case. (c) *Reason over-cap: reject versus truncate* — Standard/Claude notes a hard `invalid_params` on a 300-character reason strands an agent that is already blocked, and suggests truncate-with-warning; the safe half of that finding (the error must state the cap) is already captured in M3.
  - Sources: Adversarial/Gemini (challenged decisions, Q2/Q3), Standard/Gemini (weakness 1, Q1), Evolutionary/Gemini (Q2/Q4), Standard/Claude (G10, Q13).

- **S10: The "Jump to Latest Unread" copy and enablement across 14 call sites**
  - Why deferred: design-needed, with a hard scheduling constraint
  - Summary: The plan keeps ⌥V and every existing call site as one action (correct — "one key, one point of interaction" is load-bearing in the spec) but does not touch the copy. Three call sites render user-facing text saying "Jump to Latest Unread" (`NotificationsPage.swift:111,124`; `statusMenu.jumpToLatestUnread`; `shortcut.jumpToUnread.label` in the shortcuts settings pane). After this change, pressing a button so labelled can take you to a flagged surface with no unread notification. Standard/Codex adds that the status-menu item's *enablement* derives from unread count, so with one flag and zero signal-eligible unread it would be simultaneously disabled and inaccurate. Both reviewers agree it must be resolved; renaming means a six-locale re-translation, so **the decision has to be made in Phase 1 to freeze strings before the Phase 6 translator stage**. There is also an open sub-question: should the Notifications-page button stay notification-only, since a flag writes no notification record? Standard/Claude leans toward unified everywhere.
  - Sources: Standard/Claude (G4, Q6), Standard/Codex (blocking gap 6, Q13).

- **S11: Bonsplit submodule sequencing and push target**
  - Why deferred: ambiguous
  - Summary: Two separate points. Adversarial/Claude and Evolutionary/Codex both recommend landing the generic Bonsplit presentation seam as its own reviewed submodule commit *before* the c11 feature wiring, so the API is settled and pushed before anything depends on it — reverting a submodule pointer mid-ticket is painful and the plan's own push-before-pointer discipline makes iteration expensive. Separately, Standard/Gemini asks a factual question the plan never answers: is "push to remote `main`" the Stage 11 fork's main, or does it imply an upstream `almonk/bonsplit` merge gating the parent pointer? The plan says to offer it upstream in the handoff rather than open an upstream PR during the task, which implies the fork — but it should say so explicitly.
  - Sources: Adversarial/Claude (C5), Evolutionary/Codex (Phase 3, suggestion 11, Q10), Standard/Gemini (Q4).

- **S12: Why did C11-183 ship a flagged-motion behavior contradicting a spec that already existed?**
  - Why deferred: author-intent-needed / process question
  - Summary: The plan's seam audit concedes that the shipped renderer animates flagged-working with the normal stepped fill and leaves flagged idle/cold static, contradicting the binding spec's "breathe for every flagged non-waiting state" — verified at `Sources/ContentView.swift:11450-11458`. The plan reverses it on spec authority alone. Adversarial/Claude accepts the reversal but asks whether C11-183's behavior was a considered simplification (in which case the reversal deserves an argument) or an oversight (in which case the process gap deserves one sentence), since the mechanism that let a prerequisite ticket ship against an existing spec is still in place.
  - Sources: Adversarial/Claude (failure pattern 4, C4, Q24).

---

## Evolutionary worth considering (do not apply silently)

- **E1: Flags are a question with no answer channel, and `Sources/Mailbox/` is the answer channel c11 already ships**
  - Summary: The motivating example throughout is "Need a call on schema migration vs dual-write," but the operator's entire reply vocabulary is an X. Meanwhile the mailbox system is a complete inter-agent transport with addressing, a dispatch log, delivery events, ambiguity resolution across workspaces, and a `c11 mailbox send` CLI. The v2 shape is a banner reply field that dispatches a mailbox envelope to the flagging surface and lowers with `resolution: answered`; the ask for v1 is only that the banner reserve a second affordance slot, that `flag.lowered` carry an optional `note`, and that the plan's non-goals name the successor. Evolutionary/Gemini's supervisor-swarm and Evolutionary/Codex's routed-suppression ideas are the same lever from different angles: an Overwatch agent tailing `flag.raised` that answers what it can and batches the rest converts flags from *operator attention* into *the cheapest competent attention*, which is the actual scaling answer past thirty agents.
  - Why worth a look: it changes the unit of operator throughput from acknowledging a blocked agent to unblocking one, and the transport already exists and is already tested.
  - Sources: Evolutionary/Claude (§1, mutations, Q1/Q7), Evolutionary/Gemini (supervisor swarm, Q1), Evolutionary/Codex (routed suppression, pluggable sinks, Q11).

- **E2: Make the signal-eligibility builder take a policy struct, even with one field today**
  - Summary: The raw-versus-signal refactor is the most reusable thing in the ticket, but only if eligibility is a pure function over an input struct rather than an inline suppression read. Written as `eligibility(for: notification, policy: AttentionSignalPolicy)`, do-not-disturb becomes one boolean, quiet hours two timestamps, per-workspace mute one set, and "only signal me for orchestrators" a role filter. Evolutionary/Claude notes that for someone running thirty agents overnight, a fleet-wide DND is plausibly more valuable than per-surface suppression — and this ticket accidentally builds ninety percent of it.
  - Why worth a look: near-zero marginal cost inside work already planned, and it is the seam every future notification policy will need.
  - Sources: Evolutionary/Claude (§"What's Really Being Built" layer 2, mutations, suggestion 6), Evolutionary/Codex (attention policy layer).

- **E3: Decide suppression batching and launch inheritance explicitly rather than by omission**
  - Summary: "Orchestrator with subagents" is named as *the* shape suppression serves in three documents, yet the primitive is per-surface with no batch form and no inheritance — an orchestrator suppressing an existing fleet of thirty issues thirty calls. Two small options: accept repeated `--surface` refs on suppress/unsuppress (fully compatible with the C11-165 explicit-ref rule, since there is still no implicit target), and/or default an agent-originated `launch-agent` invoked *from* a suppressed surface to a suppressed child. Inheritance is the more opinionated one, and retrofitting it after agents have written scripts against non-inheriting behavior is a behavior break — which is the argument for deciding it now either way.
  - Why worth a look: the batch form is nearly free, and the inheritance question determines whether the orchestrator pattern is one rule or N calls.
  - Sources: Evolutionary/Claude (§6, suggestion 7, Q4/Q9).
