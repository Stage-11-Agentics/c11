# Standard Plan Review — C11-184 (Flagged and suppressed agents)

- **Plan ID:** c11-184-plan
- **Model:** Claude
- **Reviewed:** 2026-07-28 17:26
- **Plan file:** `.lattice/plans/task_01KYMTXQVWCXCF0TGN5ZWG341E.md`
- **Binding inputs read:** `docs/c11-flagged-agent-plan.md`, `docs/c11-attention-model-skill-section.md`, `docs/c11-mark-vocabulary.md`, `CLAUDE.md`
- **Code verified against:** `Sources/Sidebar/SidebarActivityProjector.swift`, `Sources/SurfaceLivenessDeriver.swift`, `Sources/SurfaceMetadataStore.swift`, `Sources/TerminalNotificationStore.swift`, `Sources/Workspace.swift`, `Sources/ContentView.swift`, `Sources/WorkspaceContentView.swift`, `Sources/Events/EventEnvelope.swift`, `CLI/c11.swift`, `vendor/bonsplit/Sources/Bonsplit/**`

---

## Executive Summary

This is a genuinely good plan. It is unusually well grounded: I spot-checked roughly a dozen of its claims about the current tree and every one held. `WorkspacePulseAgent.flagged/.suppressed` and `presentedState` exist as forward scaffolding exactly as described (`SidebarActivityProjector.swift:29-56`). `BonsplitActivityMarkMotion` already ships `steppedFill / easedDip / binaryFlash` and a stable-phase shared clock, so "add a `breathe` channel" is a genuinely small delta rather than a hand-wave. `BonsplitActivityAnimationEnabledKey` really is the single folded permission the plan says must be split. `NotificationIndexes` really does carry only `unreadCount` + `unreadCountByTabId`. The author read the code, not just the spec. That is rarer than it should be and it is the main reason I trust the rest.

The architecture is also right in the one place that matters most: **one serialized commit boundary owning metadata write + projection + event + delivery**, with the generic `surface.set_metadata` route explicitly barred from bypassing it. Most implementations of this feature would let `flag` be "just another metadata key," and then spend three weeks chasing states where the sidebar, the tab chip, the events stream, and the banner disagree. Closing the bypass in the plan rather than discovering it in review is the single strongest decision in the document.

**The single most important thing: this is not one ticket.** Six phases, ~22 owned source files, a submodule change with its own push protocol, a notification-store index refactor, a new AppKit portal overlay, a CLI + socket surface, six locales, a skill sync, and a hard pre-merge fleet-scale latency gate that requires a measurement harness **that does not exist in this repo**. The plan's own "commit in coherent units" list already decomposes cleanly into three independently shippable PRs. Shipping it as one PR converts every one of the plan's careful gates into a single all-or-nothing merge, and puts the riskiest item (a ≤1 ms p95 typing-latency gate on a build with 40+ animating leaves) at the very end where failing it invalidates weeks of work.

Secondary but real: there are four concrete gaps the plan does not currently cover, detailed below — a mark-sync early-return that will silently swallow flag color changes, a launch-time `--flag` that will fire a system notification at the operator who just typed the command, a `jumpToLatestUnread` semantics change across 14 call sites whose user-facing label still says "Jump to Latest Unread," and a missing `by` field on `flag.raised` that makes the event stream asymmetric.

**Verdict: Needs revision — but revision measured in hours, not a rethink.** The architecture stands. Split the PR, close the four gaps, resolve the held Phase 3 decision before Phase 3 starts, and specify the latency instrument.

---

## The Plan's Intent vs. Its Execution

The underlying intent, from the feature spec, is a signal-to-noise repair: *waiting is a flat tier that both under-signals (the genuinely blocked agent looks like nine finished ones) and over-signals (the fired-off sweep demands attention it does not need).* Flags fix the first; suppression fixes the second. The headline case is the combination — "don't tell me when you finish, do tell me if you get stuck."

The plan serves that intent faithfully, and in a couple of places it serves it better than the spec does. Three examples:

1. The spec says suppression "filters in the projector" and "in the notification store's signal layer." The plan correctly recognizes that those are two *derived* views of one canonical truth and insists on a single commit boundary rather than two independent filters. That is the difference between a feature that works and one that drifts.
2. The spec's decision provenance contains a genuine internal collision ("suppressed marks never animate" vs. "flags override suppression"). The plan resolves it explicitly at the right layer — split base-motion from explicit-motion eligibility rather than special-casing flag inside the base gate.
3. The plan noticed that C11-183's shipped renderer behavior (flagged working uses the normal stepped fill; flagged idle/cold static) *contradicts* the binding spec (breathe for every flagged non-waiting state), and explicitly says to replace the scaffolding. A plan that had only read the spec would have shipped a bug here.

**Where intent drifts:**

- **Scope drift toward completeness.** The intent is "the operator can tell blocked from done at fleet scale." The plan delivers that plus an exhaustive matrix of every lifecycle × flag × suppression × motion-setting × Reduce-Motion combination, validated in two renderers, with screenshots for ten scenarios and a p50/p95 latency protocol. Every individual item is defensible. Collectively they push the ticket past the point where it can be reviewed, validated, or reverted as a unit. The completeness instinct is correct; the packaging is not.
- **The `jumpToLatestUnread` change is described as a no-op on call sites, but it is not.** The plan says "all existing call sites and the Option-V binding stay one action." That is true mechanically and false semantically. There are 14 call sites, including the Notifications page's **"Jump to Latest Unread"** button, the status-menu item of the same name, and the update titlebar accessory. After this change, pressing a button labeled "Jump to Latest Unread" can take you to a flagged surface with *no* unread notification. The intent (one point of interaction) is right; the execution leaves user-facing copy lying. The label is a localized string (`shortcut.jumpToUnread.label`, `notifications.jumpToLatestUnread`, `statusMenu.jumpToLatestUnread`) and renaming it means a re-translation pass in all six locales — which is exactly why it needs to be decided in Phase 1, not discovered in Phase 6.

---

## Architectural Assessment

### The decomposition is right at the model layer

Two orthogonal persisted modifiers over an unchanged four-case lifecycle, with a pure presentation reducer computing the projection, is the correct shape. The alternative — a linear `suppressed | normal | flagged` enum — cannot express the headline case and the spec says so. The plan does not relitigate this, correctly.

Making `presentedState` a pure derived property that both the sidebar and the tab resolver consume is the right anti-drift move. The one thing I'd tighten: the plan says "extend `SurfaceTabActivityResolver` (or introduce a sibling pure reducer)." Choose. Two reducers that must agree is precisely the failure mode the plan's own risk register calls "spec precedence implemented differently in two renderers." Extend the existing resolver so there is exactly one function that maps (lifecycle, unread, flag, suppression) → presented state, and have both `WorkspacePulseAgent.presentedState` and the Bonsplit tab path call it.

### The commit boundary is right, but it is stated as a requirement, not designed

This is my largest technical reservation. The plan says:

> One serialized `SurfaceAttentionService` ... owns the complete commit boundary: canonical metadata write/clear, original active-epoch timestamp, typed projection/index refresh, signal-index refresh, event emission, and optional direct system delivery. A mutating socket response is sent only after that whole commit is observable.

And separately:

> parse, validate, resolve, and dedupe on the socket worker; never use `DispatchQueue.main.sync`. Hop with `DispatchQueue.main.async` only for the minimum model/UI projection mutation, then complete the request after the serialized attention commit finishes.

Those two paragraphs are in tension and the plan does not say how they reconcile. The commit spans **two different isolation domains**: the metadata store's serial queue (off-main) and the main actor (projection, notification store, `UNUserNotificationCenter` delivery, banner host). "Serialized" and "no `main.sync`" together mean you need an explicit asynchronous continuation: the service's serial queue does the canonical write, then dispatches the main-actor phase `async`, and the socket response is resolved from a completion invoked at the *end* of the main-actor phase. That is implementable and it is almost certainly what the author means — but "almost certainly what the author means" is not a design an implementer can execute without re-deriving it, and re-derivation is where `main.sync` sneaks back in under deadline pressure.

**Ask for the concrete ordering primitive before Phase 1 starts.** Specifically: what object holds the pending socket responses, what happens if a second mutation for the same surface arrives while the first is mid-main-hop, and what the response contract is if the main hop never runs (app terminating). The plan's idempotency rules imply per-surface serialization, which suggests a per-surface pending-op key rather than a global queue.

There is also a subtle ordering hazard the plan does not name: the plan requires `raise()` to emit `flag.raised` **and** refresh projections **and** call the direct-notification seam. If event emission happens on the serial queue and projection on main, an Overwatch consumer tailing events can observe `flag.raised` before `flag.list` reflects it. For a feature whose stated integration story is "events are the Overwatch integration," that read-your-writes gap matters. Either emit the event from the main-actor tail of the commit, or state explicitly that events lead the projection and that consumers must tolerate it.

### The Bonsplit seam is well chosen

Extending the generic host-presentation seam rather than teaching Bonsplit about flags is correct and matches the repo's stated posture on upstream divergence. C11-183 already established the shape (`BonsplitActivityMarkMotion` is policy-free; `BonsplitActivityMarkAnimation` provides pure samplers; the host owns policy), so this is continuation rather than invention. Adding `breathe` alongside `steppedFill / easedDip / binaryFlash` and splitting `bonsplitActivityAnimationEnabled` into base/explicit is a small, clean, genuinely upstream-offerable delta. Good.

The plan's instruction to flag it in the PR rather than opening an upstream PR during the task is the right call — upstream round-trips are not on this ticket's critical path.

### The phase ordering is right; the PR packaging is not

Phases 0→6 are correctly ordered: canonical model before primitives before signal layer before rendering before banner before localization. Rendering last is right (it is the part that changes most under latency-gate pressure). Localization last is right (English must freeze first).

But the plan's own commit list —

> model/tests; primitives/launch; signal/navigation; renderer/submodule; banner/UI; localization/skill

— is already three natural PRs:

- **PR 1 (Phases 0–2):** canonical metadata, pure reducer, events, socket + CLI + launch flags. Fully headless, fully logic-testable, zero rendering risk. Ships real value: agents can flag, Overwatch can consume events, `get-metadata` round-trips.
- **PR 2 (Phase 3):** signal-eligible index split, waiting-edge rebasing, direct flag delivery, navigation. This is where the highest *correctness* risk lives (raw/signal drift, double-count, edge emission). Reviewing it in isolation against a stable base is worth a lot.
- **PR 3 (Phases 4–6):** both renderers, banner, motion policy, latency gate, localization, skill. This is where the *validation* risk lives, and it is the only part that needs the tagged build, the 20-agent harness, and computer-use approval.

The counterargument is that the skill section documents commands that must exist — but the skill lands in PR 1 (the primitives PR) by the staged doc's own landing rule, and PR 1 is exactly where those commands ship. There is no real coupling forcing a single PR.

The gain from splitting is not aesthetic. It is that a failed latency gate in PR 3 no longer holds the model, the primitives, and the events hostage; and it means the reviewer's "one fresh correctness/threading review, one focused fix pass, one terminal re-review" budget (which is appropriately bounded for a normal PR) is not being asked to cover 22 files of cross-cutting change in one sitting.

---

## Is This the Move?

Mostly yes, with two bets I'd re-examine.

**Bet 1 (good): canonical metadata as the persistence substrate.** Reusing the existing `explicit`-tier metadata path means zero new persistence code, free snapshot/restore, free `get-metadata` introspection, and free cross-process visibility. This is the highest-leverage decision in the whole design and the plan takes it without ceremony. The cost — that `surface.set_metadata` becomes a bypass vector — is the direct consequence, and the plan closes it explicitly with adversarial coverage. Correct trade, correctly mitigated.

**Bet 2 (good): flags do not write `TerminalNotificationStore`.** Inherited from the spec, and the plan restates it as a risk with a test assertion. This is the kind of thing that looks like an implementation detail and is actually the difference between a coherent pulse and a double-counting one.

**Bet 3 (questionable): the ≤1 ms p95 hard gate, with no instrument.** I searched the repo. There is no keystroke-to-paint latency harness — the only hits for typing-latency measurement are in prose (`docs/c11-textbox-port-plan.md` and its review pack). The plan asks for p50/p95 keystroke-to-paint timing across five configurations at 20+ agent surfaces with a ≤1 ms delta threshold, and treats it as a hard pre-merge blocker.

Two problems. First, **building the instrument is an unscoped subtask hidden inside a validation step**, and it is not small — reliable keystroke-to-paint measurement on macOS with a Ghostty-embedded renderer is its own engineering problem. Second, **1 ms is likely below the noise floor** of anything you'll build quickly; run-to-run variance on a 20-surface fleet will plausibly exceed the threshold you're trying to detect, and you'll spend the validation budget arguing about whether a 1.4 ms delta is real.

I would either (a) scope the harness as an explicit named deliverable with its own phase, or (b) restate the gate in terms you can actually measure — subjective typing degradation on a controlled 20-agent build, plus objective proxies you *can* count reliably: `TabItemView` body-evaluation count during a typing burst (the repo already has `BonsplitDebugCounters`), shared-clock subscriber count, and CPU during sustained typing. The proxies are arguably the better gate anyway, because they fail *diagnostically* — "body churn went up 40×" tells you what to fix; "p95 moved 1.3 ms" does not.

The fallback ladder (stepped fill off → dip off → static base; flags static violet independently) is well constructed and pre-registered, which is the right discipline. It just needs a gate it can actually be triggered by.

**Bet 4 (questionable): all validation deferred to CI.** The operator's constraint (no local `xcodebuild test`, including `c11-logic`) is explicit and I am not relitigating it. But the plan should acknowledge the consequence: **the inner loop for a 22-file cross-cutting change becomes a CI round-trip.** That is a materially slower and more error-prone loop than the repo normally runs, and it is another argument for smaller PRs — a 6-file PR with a CI-only test loop is workable; a 22-file one is a grind. The plan's compensating move (`build-for-testing` as a link/membership check, with an explicit warning not to treat it as assertion evidence) is exactly right and well stated.

---

## Key Strengths

1. **Verified against the tree, not just the spec.** Every structural claim I checked was accurate, including the subtle ones (C11-183's shipped renderer contradicting the binding spec; `NotificationIndexes` carrying only raw counts; the single folded animation-permission environment key). This is the strongest signal in the document.

2. **One canonical truth, one commit boundary, explicit bypass closure.** The principle is "derived views may be many; the write path must be one." The plan not only states it but enumerates the bypasses (generic set/clear, replace, clear-all, restore, launch stamping, detach/transfer, close, prune) and demands adversarial coverage for each. Most plans get the happy path right and lose to restore-and-transfer six months later.

3. **Idempotency and the flag epoch are specified precisely.** "An active-to-active reason revision preserves the original timestamp, emits one new `flag.raised` and one policy-governed updated notification, but never creates a second queue entry. Only an explicit lower followed by a new raise starts a new epoch." That is a real semantic decision with a real failure mode behind it (an agent that revises its reason every thirty seconds would otherwise perpetually reset its own queue age and never get seen). Naming it in the plan is the mark of someone who thought about adversarial agent behavior.

4. **The held Phase 3 decision is isolated correctly.** "Exactly one policy branch at the direct flag delivery call site" with an explicit list of what may *not* depend on it (waiting eligibility, history, lifecycle, projector, queue, banner, routine delivery) turns an open question from a blocker into a parameter. This is the right way to carry an unresolved decision through a plan.

5. **Motion policy decomposition.** Recognizing that "Static marks disables base motion but flag motion still runs; Reduce Motion disables both" cannot be expressed by one boolean, and splitting the generic permission rather than hacking a flag exception into the base gate, is correct at exactly the layer where correctness is cheap.

6. **The banner mounts in the portal layer.** Inherited from the spec, but the plan's restatement of *why* (a layout-flow banner resizes the PTY and garbles TUI rendering mid-run) plus the explicit gate ("raising/lowering never changes PTY rows/columns") is the right treatment for a self-inflicted-bug risk on a feature whose purpose is to interrupt cleanly.

7. **The risk register is real.** Most plan risk sections are decoration. This one names failure modes that map to specific mitigations and specific tests (raw/signal drift → one pure index builder + transition tests; flag queue age reset → source timestamp preservation + deterministic tie-break).

---

## Weaknesses and Gaps

### G1. The mark-sync early return will silently swallow flag color changes

`Workspace.syncSurfaceTabActivityStateForPanel` guards on:

```swift
guard existing.activityState != activityState
    || existing.showsNotificationBadge != shouldShowLegacyUnread else { return }
```

A flag raised mid-**working** does not change `activityState` (still `.running`) and does not change the badge. The guard early-returns, `updateTab` is never called, and **the surface tab never turns violet.** This is the plan's own headline scenario #2 ("A flag raised mid-working: both marks snap violet"), and it will fail on first run.

The plan lists `Sources/Workspace.swift` with "lifecycle/presentation sync" among its owned seams, so it is arguably in scope — but this specific early-return is the kind of thing that is obvious in hindsight and invisible in review. **Name it explicitly in the plan** and require the guard to compare the full presentation value, not just `activityState`. Add a regression test that asserts a flag raise on a working surface propagates to the tab.

### G2. `launch-agent --flag` will fire a system notification at the operator who just typed it

The plan's `raise()` semantics unconditionally call the direct-notification policy seam. Launch-time modifiers are declared "operator-originated." So `c11 launch-agent --type claude-code --flag "watch this migration"` will, per the plan as written, deliver a `UNUserNotification` to the operator roughly 200 ms after they pressed Enter, announcing a flag they just raised themselves.

The spec's model of a launch-time flag is "a mission the operator intends to watch" — a *visual* marker, not an interrupt. The direct notification exists because "a flag is exactly the signal that should reach the operator in another application," which is meaningless for an operator-initiated raise on a surface they are looking at.

**Recommendation:** the direct-delivery seam should take the origin into account — `by: .operator` raises do not deliver. That is a one-line rule and it should be stated in the plan, not left to the implementer. It also interacts with the held Phase 3 decision (which is about suppressed surfaces) — keep them as two independent conditions at the same call site, not one tangled predicate.

### G3. `flag.raised` has no `by` field — the event taxonomy is asymmetric

From the spec (faithfully copied into the plan):

```
flag.raised       payload: { reason: String }
flag.lowered      payload: { by: "operator" | "agent" }
flag.suppressed   payload: { by: ... }
flag.unsuppressed payload: { by: ... }
```

But the spec is equally emphatic that **"a flag arrives from either side"** — operator at dispatch or agent mid-run. An Overwatch consumer tailing `c11 events tail` therefore cannot distinguish "the operator flagged this mission at dispatch" from "the agent hit a blocker," which are completely different routing decisions. Three of the four events carry provenance; the one where provenance is most operationally meaningful does not.

This looks like a spec oversight rather than a deliberate omission. The plan should either add `by` to `flag.raised` (my recommendation — it costs nothing, and the plan already has an `operator | agent` vocabulary and an explicit socket field for trusted operator-originated actions) or state explicitly that it was considered and rejected. Adding a field to an event payload later is a compat problem; adding it now is free.

### G4. `jumpToLatestUnread` semantics change without a copy change

14 call sites, three of which render user-facing text that says "Jump to Latest Unread":

- `Sources/NotificationsPage.swift:111,124` — button labels
- `Sources/AppDelegate.swift:13226` — `statusMenu.jumpToLatestUnread`
- `Sources/KeyboardShortcutSettings.swift:67` — `shortcut.jumpToUnread.label`, shown in the shortcuts settings pane
- `Sources/Update/UpdateTitlebarAccessory.swift:1017`

After this change all of them mean "jump to whoever needs you most, flags first." The plan explicitly keeps them as one action (correct — the spec's "one key, one point of interaction" is load-bearing) but does not touch the copy. Renaming the strings is a six-locale re-translation, which means **the decision must be made in Phase 1 so the strings are frozen before the Phase 6 translator stage**, not discovered afterward.

There is also a behavioral question the plan does not answer: should the **Notifications page** button jump to a flag? That page is specifically about the notification list, and a flag writes no notification record. An argument exists for keeping that one call site notification-only. I lean toward keeping the unified action everywhere (divergence is worse than a slightly loose label) but it should be a stated decision.

### G5. The `flag.list` socket method has no CLI counterpart

Phase 2 adds socket methods `flag.raise / lower / list / suppress / unsuppress`, and CLI commands for four of the five. There is no `c11 flags` / `c11 list-flags`. The staged skill section does not document one either.

That is a real hole for the stated integration story. An orchestrator that dispatched a fleet and wants to know which children are flagged has an events stream (push) and a socket method it cannot reach from the shell. The plan says "the Flagged Agents row follows that existing scope; this does not add the ... cross-workspace dashboard" — fine, no UI — but a read command is not a dashboard. Add `c11 flags [--json]` in Phase 2, and a line to the staged skill section.

Related: the plan never states whether `flag.list` is workspace-scoped or app-global. Given the Flagged Agents row is app/window-global by inheritance from the notification store, `flag.list` should be app-global with workspace refs in each entry. Say so.

### G6. The latency gate has no instrument (detailed above)

No keystroke-to-paint harness exists in the repo. Either scope it as a deliverable or restate the gate in terms of measurable proxies (`BonsplitDebugCounters` body-evaluation counts, clock subscriber count, sustained-typing CPU) plus a subjective pass.

### G7. Test seam for "two flags with controlled timestamps" is not specified

Validation scenario 9 requires two flags with controlled raise timestamps to prove oldest-first ordering. The raise timestamp is defined as "the metadata source timestamp." There is no stated injection seam for it. Either the pure selector takes timestamps as input (easy — and the plan does say the selector is pure, which implies this) or the service takes an injectable clock. State which. Without it, "two flags with controlled timestamps" becomes "raise one, sleep, raise another," which is a flaky test.

### G8. Second `WorkspacePulseProjector.project` overload not addressed

`SidebarActivityProjector.swift` has a second `project(hasWorkspaceDemand:surfaceStates:...)` overload taking bare `[WorkspacePulseState]` with no agent records and therefore no modifiers. If it is live, it is a path where suppression and flags silently do not apply. The plan should say whether it is dead, whether it needs the modifier fields, or whether it is intentionally modifier-free.

### G9. Sticky flags across relaunch on a dead surface — confirmed intent?

Flags are canonical metadata and survive relaunch. A flagged agent whose process is long gone restores as flagged-and-cold, breathing violet, and sits in the oldest-first queue at the head forever (it is the oldest). Option-V will send the operator to a dead surface first, every time, until they manually lower it.

That is arguably correct per "sticky-until-acted-on is the whole point," and the plan's "skip stale/unopenable surfaces and try the next flag" partially covers it — but *restorable* is not the same as *stale*, and a restored cold surface is openable. Worth an explicit decision: does a cold flagged surface stay at the head of the queue, or does the selector deprioritize (not skip) cold flags?

### G10. Reason-length cap of 256 is plan-introduced

The spec says "one line, required." 256 characters is the plan's number. Reasonable, but it is a new user-visible constraint (an agent writing a 300-char reason gets a hard `invalid_params` rejection mid-run, which for an agent that is *already blocked* is a bad failure). Consider truncate-with-warning rather than reject, or at minimum make sure the error message states the cap so the agent can retry successfully. The plan's "validate before mutation, reject atomically" is right for structure (blank/multiline/non-string); length is the one where rejection is most likely to strand a blocked agent.

---

## Alternatives Considered

**Single PR vs. three PRs.** Covered above. The plan chose single; I would choose three. The plan's own commit-unit decomposition is the split, so the cost of changing is close to zero and the benefit (independent review, independent revert, latency risk isolated to the last PR, workable CI-only test loop) is large.

**Canonical metadata vs. a dedicated attention store.** The plan chose metadata. Correct. A dedicated store would need its own persistence, snapshot integration, restore path, and introspection command, and would gain only isolation from the `set_metadata` bypass — which the plan closes anyway. Metadata is the right substrate and the reuse is the whole reason this feature is tractable.

**Extending `SurfaceTabActivityResolver` vs. a sibling reducer.** The plan says "or." Choose extension. Two reducers that must agree is the plan's own named risk.

**Splitting the animation permission vs. threading a policy object.** The plan splits `bonsplitActivityAnimationEnabled` into base/explicit booleans. The alternative is one host-supplied policy value carrying both channels. The split is simpler and matches the existing environment-key idiom; two booleans is the right amount of structure for two questions. Agreed.

**Unified ⌥V vs. a second shortcut.** Settled in the spec (one key, two-phase). Right call: a second shortcut would be a second thing to remember for a state that is rare by design, and would create the "which row do I trust" problem the flagged row explicitly avoids. No objection — but see G4 on the copy.

**Flag notification delivered directly vs. through `TerminalNotificationStore`.** Settled in the spec. Direct is right and the double-count argument is airtight. The consequence — a flag notification has no store record, so clicking it must focus without a read side-effect — is handled in the plan's `userInfo` design. Good.

**Suppression as a lifecycle projection vs. a visual treatment (dim).** Settled in the spec's own revision history, and the mark-vocabulary doc makes it a simplification rather than a compromise (no dim modifier to build in either renderer, opacity stays free). The accepted cost — a suppressed agent that finished and one that stalled both read idle — is explicitly named in the spec and I would not reopen it. Worth noting for the operator that this cost is *fully realized* only once suppression is in daily use, and the notifications list is the only recourse; if it chafes, the free opacity channel is the escape hatch, not a new lifecycle case.

---

## Readiness Verdict

**Needs revision.** The architecture is sound and I would not re-plan it. What changes the verdict to *ready*:

**Required (blocking):**

1. **Split into three PRs** along the plan's own commit boundaries (model+primitives+events+CLI+skill / signal+navigation / renderers+banner+localization+latency), or state an explicit reason why not.
2. **Specify the commit-boundary ordering primitive** — how a serialized off-main commit + a main-actor projection phase + a socket response resolve without `main.sync`, including concurrent-mutation-per-surface behavior and event-vs-projection visibility ordering.
3. **Close G1** — the `syncSurfaceTabActivityStateForPanel` early return, with a named regression test.
4. **Close G2** — operator-originated raises do not fire a direct system notification; keep it independent of the held suppressed-delivery branch.
5. **Resolve the Phase 3 held decision** before Phase 3 starts. It is a one-question conversation and Phase 3 cannot be validated without it.
6. **Fix the latency gate** — either scope the harness as a deliverable or restate in measurable proxies.

**Strongly recommended (non-blocking but decide before Phase 1 freezes strings):**

7. Add `by` to `flag.raised` (G3).
8. Decide the `jumpToLatestUnread` copy question and freeze the strings in Phase 1 (G4).
9. Add `c11 flags [--json]` and a skill line (G5).
10. Specify the timestamp injection seam (G7).

---

## Questions for the Plan Author

1. **Why one PR?** Your commit-unit list already decomposes into three independently shippable, independently reviewable PRs. Was single-PR a deliberate choice (and if so, against what — atomicity of the skill contract?) or the default?

2. **What is the concrete ordering primitive for the attention commit?** Specifically: which object holds pending socket responses; what happens when a second mutation for the same surface arrives while the first is mid-main-hop; and what the response contract is if the main hop never runs.

3. **Do events lead or trail the projection?** Can an Overwatch consumer observe `flag.raised` before `flag.list` reflects the flag? If yes, is that acceptable and documented?

4. **Should a launch-time `--flag` fire a system notification?** (I think clearly no — see G2.) And should operator-originated raises *in general* skip direct delivery, or only launch-time ones?

5. **Should `flag.raised` carry `by`?** Three of four attention events carry provenance and the spec insists flags arrive from both sides. Was the omission deliberate?

6. **What happens to the "Jump to Latest Unread" copy?** Rename in all six locales, or keep the label and accept that it now sometimes means something else? And should the Notifications-page button stay notification-only, or take the unified prioritized jump?

7. **Is there a `c11 flags` CLI read command?** If not, how does an orchestrator poll its fleet's flag state from the shell? And is `flag.list` app-global or workspace-scoped?

8. **How do you measure keystroke-to-paint p50/p95 at 1 ms resolution?** No harness exists in the repo. Is building one in scope, or should the gate be restated in proxies (`BonsplitDebugCounters` body-eval counts, clock subscriber count, sustained-typing CPU) plus a subjective pass?

9. **What is the injection seam for flag raise timestamps in tests?** Does the pure selector take timestamps as parameters, or does the service take an injectable clock?

10. **Should a restored cold flagged surface hold the head of the oldest-first queue indefinitely?** "Skip stale/unopenable" does not cover a restorable-but-dead surface. Deprioritize cold flags, or leave them at the head as the sticky contract implies?

11. **`SurfaceTabActivityResolver` extension or sibling reducer?** The plan says "or." Which, and how do you guarantee the sidebar and the tab chip cannot disagree?

12. **Is the second `WorkspacePulseProjector.project(surfaceStates:)` overload live?** If so, does it need modifier support, or is it intentionally modifier-free?

13. **Over-cap reason: reject or truncate?** A hard `invalid_params` on a 300-char reason strands an agent that is already blocked. Is 256 the right cap, and is rejection the right failure mode?

14. **Does `flag.list` (and the Flagged Agents row) span all windows, or the current window?** The plan inherits the notification store's "app/window-global" scope by reference but never states which it actually is.

15. **What clears a flag when a surface is closed?** The plan mentions prune hooks. Does closing a flagged surface emit `flag.lowered`, and with what `by`? An Overwatch consumer tracking open flags needs the close to be observable.

16. **Is the Flagged Agents row's count app-global while the sidebar it lives in is workspace-scoped?** If the operator is in workspace A and the only flag is in workspace B, the row appears in A and the jump navigates away. Intended (I think yes — flags jump the queue globally), but worth confirming, since it is the one place this feature reaches across workspaces despite the "no cross-workspace aggregation" non-goal.

17. **What is the fallback if the Bonsplit submodule change turns out to need a c11-specific concept after all?** The plan is firm that Bonsplit stays generic. If the violet + alternate-core + explicit-motion triple cannot be expressed generically without contortion, is the answer to contort, or to accept a scoped divergence and document it?
