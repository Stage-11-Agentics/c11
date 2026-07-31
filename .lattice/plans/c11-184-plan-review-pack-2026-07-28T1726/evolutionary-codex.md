# Evolutionary Plan Review — c11-184-plan — Codex

## Executive Summary

The largest opportunity is to recognize that C11-184 is not principally a flag UI. It is the first explicit **operator-attention control plane** in c11: durable agent assertions, policy over which lifecycle facts become demands, routing into human-visible surfaces, and an event protocol that other agents can consume without screen polling.

The plan is unusually complete and is directionally right. Its separation of raw notification history from signal eligibility, its insistence that flag and suppression remain orthogonal modifiers, and its generic Bonsplit boundary are the correct foundations. With four architectural amendments, it can become substantially stronger:

1. Make the flag epoch genuinely persistent. The current store preserves a source timestamp only for an identical write; a changed reason gets a new timestamp. The proposed active-to-active reason revision therefore cannot preserve its oldest-first queue age across relaunch without a new persisted epoch seam.
2. Separate the atomic state transaction from best-effort delivery effects. Metadata, projections, and indexes can commit together; `UNUserNotificationCenter` and custom delivery cannot participate in that atomic boundary.
3. Reconcile the binding spec before implementation. The spec still says suppressed surfaces deliver no system notification, while the authoritative Phase 3 decision says a direct flag notification pierces suppression.
4. Derive operator/agent attribution from a trusted call path, or explicitly call it claimed attribution. A socket field available to every local agent is not, by itself, proof that the operator acted.

The evolved version should still ship the same v1 product. The difference is that its internal shape becomes reusable: snapshot plus deltas, durable attention epochs, explicit routing policy, and replaceable delivery sinks. That is the foundation for hierarchical fleets rather than a one-off violet modifier.

## What’s Really Being Built

At the surface, the plan adds two metadata fields, five socket methods, four CLI commands, two visual treatments, a banner, and a priority jump.

Underneath, it creates four distinct layers:

1. **Operational truth:** the four-state lifecycle and raw notification history.
2. **Attention policy:** flag and suppression decide which truth is promoted into operator demand.
3. **Attention projection:** counts, marks, navigation order, banners, and event edges.
4. **Attention delivery:** in-app signals, system notifications, custom commands, and eventually other routers.

That decomposition is the real asset. Today, waiting is an incidental consequence of unread records. After C11-184, c11 can answer a more important question: **who is owed attention, why, in what order, and through which channel?**

The `flag.list` snapshot plus `flag.*` event deltas also forms the beginning of an external attention API. Overwatch or another orchestrator can reconcile current state once, then follow ordered events instead of polling terminal screens. That is a much larger capability than the UI alone.

## How It Could Be Better

### 1. Make the durable model explicit

`SurfaceMetadataStore` currently stamps a new `SourceRecord.ts` whenever a key’s value changes, while an identical value/source write preserves the prior timestamp. An active flag reason revision is a changed value. Therefore:

- the source timestamp moves forward;
- the in-memory attention index may remember the original raise time;
- a relaunch restores only the revised flag’s newer timestamp;
- oldest-first queue order silently changes after restart.

The plan should choose and document one durable solution:

- persist a paired `flag_since` or `flag_epoch` value alongside the reason; or
- add a narrowly scoped store mutation that changes the reason while deliberately preserving a separately defined epoch timestamp.

The first is semantically cleaner because “last metadata write time” and “active attention epoch start” are different facts. Whichever path is chosen, generic metadata set/replace/clear, transfer, restore, and launch stamping must update the reason and epoch as one transaction. Add a test that raises A, revises to B, snapshots, restores, and proves the original age and queue position remain unchanged.

### 2. Split state commit from side-effect delivery

The proposed `SurfaceAttentionService` should own one serialized **state transition**, but it should not claim atomicity with external delivery. A robust transition has two stages:

- **Commit:** validate, mutate canonical metadata, publish the typed snapshot, rebuild signal eligibility, emit the logical event, and produce a stable transition result.
- **Effects:** schedule/remove system notifications and invoke any custom delivery transport using an idempotency key derived from surface plus flag epoch.

If delivery fails, the flag should remain raised. The socket response can report committed state plus `delivery: scheduled | disabled | failed`, but it should not roll back canonical truth. This makes failure semantics honest and creates a reusable delivery seam for future transports.

### 3. Model three notification views, not two

Raw history and signal eligibility are the essential split, but external delivery has different temporal semantics from current in-app demand. In particular, when an unread record is unsuppressed:

- it should become visible to counts, Option-V, and waiting edges;
- it should not necessarily replay a desktop notification that was intentionally suppressed when created.

Represent these as three concepts:

- raw unread/history;
- current in-app demand eligibility;
- edge-triggered delivery state/receipt.

That prevents “eligible now” from accidentally meaning “deliver externally now” and gives suppress/unsuppress deterministic behavior.

### 4. Promote the flag reason into a value type

Create one `FlagReason` parser/normalizer used by the socket family, generic metadata mutations, launch flags, restore, and tests. In addition to blank/multiline/length validation, define:

- treatment of `\r`, Unicode line separators, NUL, and other control characters;
- whether the 256 cap is graphemes or UTF-8 bytes;
- trimming and normalization behavior;
- privacy guidance, because the reason can enter snapshots, the event log, Notification Center, and custom delivery commands.

This is both safer and simpler than reproducing validation at every ingress.

### 5. Make scope a first-class query parameter internally

The plan describes the current row as “app/window-global,” which is too ambiguous for an index that may outlive one window. Internally, make attention queries accept an explicit scope even if v1 exposes only the existing behavior:

- active window;
- workspace set owned by that window;
- process-wide.

Then define `flag.list`, the Flagged Agents count, and Option-V against the same scope object. This avoids a future rewrite when multi-window or cross-workspace routing becomes important.

### 6. Specify direct-notification lifecycle

An active epoch needs a stable external notification identifier. Reason revision should replace the same notification, not create another; lower, close, or prune should remove pending and delivered requests for that epoch. A click after transfer should resolve the surface’s current workspace by stable surface ID, and a click after close should fail closed.

The plan already calls out click ambiguity, but it should add these lifecycle rules and race tests explicitly.

### 7. Pin the remaining visual contract

The binary flash is exact; the breathe is not. Define its duration, opacity range, easing curve, and phase behavior once in the shared sampler so Bonsplit and the sidebar cannot drift. The static fallback should remain pre-registered.

## Mutations and Wild Ideas

### Routed suppression

The natural evolution of a Boolean `suppressed` flag is not “more suppression levels.” It is **attention ownership**:

```text
worker completion → supervising orchestrator
worker flag       → operator, or supervisor then operator
orchestrator done → operator
```

A future `attention_route` or `supervisor_surface` could preserve the v1 Boolean as shorthand for “not the operator’s routine queue.” This would solve the real orchestrator/subagent problem: suppressed work should often be quiet to the operator, but it should not be invisible to its supervisor.

Do not add this to v1. Do keep the service, event envelope, and query scope free of assumptions that the operator is the only possible sink.

### Attention receipts

`flag.lowered {by: operator}` is already a primitive acknowledgement receipt. Later, c11 could distinguish acknowledged/deferred from resolved without adding visual priority levels. That would let an agent know whether to remain blocked, continue elsewhere, or re-raise with new information.

Again, do not add a new state now. Preserve the conceptual room by treating lowering attribution as part of the protocol rather than decoration.

### Pluggable attention sinks

Once delivery is separated from the state transaction, the same flag transition can feed:

- macOS notifications;
- a custom command;
- Overwatch;
- a future mobile or remote relay;
- an audit-only sink for overnight runs.

The core should emit one idempotent delivery intent; transports decide whether and how to render it.

### Attention-quality analytics

The event stream can measure time-to-focus, time-to-lower, re-raises after operator dismissal, suppressed completions, and flags that never caused a stop. Those numbers can improve the skill guidance empirically without imposing quotas in the product. Reason text should be excluded or redacted from aggregate analysis.

## What It Unlocks

- **Hierarchical agent fleets:** quiet workers, visible orchestrators, and a rare escalation path that still reaches the human.
- **Screenless coordination:** Overwatch can consume a state snapshot and ordered deltas rather than inspecting panes.
- **Trustworthy operator scanning:** routine completions stop diluting the waiting signal, while genuine blockers gain a durable queue.
- **Transport independence:** attention truth can survive even when a notification transport is disabled or fails.
- **Replay and recovery:** persisted epochs plus events make relaunch behavior deterministic.
- **Policy experimentation:** future work can change who receives routine versus escalation signals without changing lifecycle truth or notification history.
- **Skill feedback:** event-derived outcomes can refine when agents should flag, suppress, or lower.

## Sequencing and Compounding

The current phase order is logical by subsystem, but a **walking skeleton** would reduce integration risk and teach more quickly.

### Phase -1 — reconcile contracts

Before code:

1. Amend `docs/c11-flagged-agent-plan.md` and the staged skill section so “routine suppression” and “flag escalation piercing suppression” agree everywhere.
2. Freeze the socket request/response schemas, `flag.list` scope, attribution semantics, unsuppress replay behavior, notification identity, and breathe constants.
3. Choose the persisted flag-epoch representation.

### Phase 0 — prove the attention kernel

Build the pure `FlagReason`, attention state machine, epoch behavior, projection matrix, and transition result. Test revision plus relaunch, lower plus re-raise, and every lifecycle × flag × suppression combination before UI.

Then implement one main-actor commit path and a fake delivery sink. Prove:

- no partial state is observable;
- effects occur after commit;
- effect failure does not roll back state;
- idempotent retries do not duplicate events or deliveries.

### Phase 1 — one end-to-end vertical slice

Wire one mutation ingress through:

```text
raise → canonical state → index → event → direct delivery intent
      → tab/sidebar projection → banner → navigation
```

Do the same for suppression over one existing unread record. This establishes the headline matrix before multiplying ingress paths.

### Phase 2 — fan out the ingress and lifecycle hooks

Add the full CLI/socket family, generic metadata bypass handling, launch stamping, replace/clear-all, restore, transfer, close, and prune. Each path should call the already-proven transition kernel rather than reconstruct policy.

### Phase 3 — isolate the generic Bonsplit change

Prefer landing the generic per-tab presentation and breathe sampler as its own upstream-shaped submodule commit, ideally reviewed before the c11 feature wiring. The parent feature then consumes a stable generic seam instead of developing submodule API and product policy simultaneously.

### Phase 4 — human surfaces and exact visuals

Complete both renderers, the row, banner, accessibility, focus restoration, and notification response. By this point the state and effect semantics are already fixed.

### Phase 5 — instrumentation before the expensive validation

Add debug-only subscriber-count and body-churn evidence before the fleet-scale run. Establish the static baseline first, then measure each motion channel independently. This turns the fallback ladder into a quick decision rather than a late forensic exercise.

### Phase 6 — localization, skill sync, independent review, validation

Keep the existing final stages, including the explicit computer-use approval boundary, one tagged launch, CI-only XCTest execution, skill sync, and bounded review budget.

## The Flywheel

The product flywheel is:

```text
suppressed routine work
        ↓
less operator noise
        ↓
flags remain rare and trusted
        ↓
operator responds faster to real blockers
        ↓
agents learn that precise flags work
        ↓
better reasons and more disciplined suppression
        └───────────────────────────────────────↺
```

The technical flywheel is parallel:

```text
typed attention state
    → deterministic events
    → better orchestration and measurement
    → evidence-backed skill guidance
    → cleaner agent behavior
    → higher-quality attention state
```

To start both loops, preserve signal scarcity and record enough non-sensitive timing evidence to distinguish useful flags from noisy ones. Do not add enforcement before real data exists.

## Concrete Suggestions

1. Add an authoritative “attention transition table” covering old state, command, new state, event, waiting edge, delivery intent, and idempotency result.
2. Persist `flag_since`/`flag_epoch`, or add an equally explicit epoch-preserving store primitive; test reason revision across snapshot restore.
3. Define `AttentionTransitionResult` with committed snapshot, emitted edge/event information, and a separate delivery outcome.
4. Use a stable direct-notification identifier based on surface plus flag epoch; replace on reason revision and remove on lower/close/prune.
5. Decide that unsuppressing an old unread record restores in-app demand but does not replay desktop delivery, unless the operator explicitly chooses otherwise.
6. Derive `by: operator` from AppKit/UI paths. If socket callers may supply it, document it as claimed attribution rather than a security boundary.
7. Introduce a single `FlagReason` type and reject all line/control forms that cannot render safely across banners, logs, and system notifications.
8. Make `flag.list`, Option-V, and the sidebar row consume one scoped query and one deterministic ordering implementation.
9. Specify the breathe waveform numerically and keep all four motion samplers in the shared generic clock module.
10. Add concurrency tests for notification arrival racing with suppress, flag revision racing with lower, close during delivery, transfer before notification click, and clear-all during an active flag.
11. Pre-land or at least separately commit/review the generic Bonsplit seam before c11 UI policy wiring.
12. Add downgrade/restore coverage: an older build should preserve unknown attention metadata, and a new build should rehydrate it without queue-age loss.
13. Expose debug-only clock subscriber counts and transition traces so the fleet validation can prove why a rung passed or failed.
14. Treat `flag.list` plus the events stream as snapshot-plus-delta protocol and document how consumers recover after a dropped event or restart.

## Questions for the Plan Author

1. What is the canonical persisted representation of the original flag epoch after an active reason revision?
2. Should a socket mutation succeed when canonical state commits but system delivery fails, and what delivery outcome should its response expose?
3. On lower, close, or prune, should c11 remove the flag’s already-delivered Notification Center entry as well as pending requests?
4. When an unread suppressed surface is unsuppressed, should it only re-enter the in-app queue, or should it also receive retroactive desktop delivery?
5. Is `by: operator` intended as authenticated fact or caller-supplied attribution? Which paths are actually trusted to set it?
6. Is `flag.list` scoped to one window, all workspaces in the process, or the caller’s workspace by default?
7. What exact duration, opacity envelope, and easing define the flag breathe?
8. May flag reasons contain sensitive project details, and what guidance or redaction is required for lock-screen notifications, event logs, and custom commands?
9. Should direct notification clicks resolve a transferred surface by stable surface ID when the embedded workspace ID is stale?
10. Can the generic Bonsplit presentation seam land as a prerequisite submodule change so the feature PR consumes rather than invents that API?
11. Does the eventual orchestration model want suppression to mean “no operator signal” or “route routine signals to my supervisor”? The answer should shape internal naming even if v1 remains Boolean.
12. Which event-derived measures would prove the feature succeeded: lower scan time, faster blocker response, fewer waiting signals, or flag rarity/trust?
