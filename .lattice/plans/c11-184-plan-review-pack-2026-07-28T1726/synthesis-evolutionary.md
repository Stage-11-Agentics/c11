# C11-184 — Evolutionary Review Synthesis

Synthesis of three independent Evolutionary/Exploratory reviews of the C11-184 plan (flagged and suppressed agents), by Claude, Codex, and Gemini.

Sources:
- `evolutionary-claude.md`
- `evolutionary-codex.md`
- `evolutionary-gemini.md`

---

## Executive Summary

1. **All three models independently reached the same reframing:** C11-184 is not a pair of visual modifiers. It is c11's first **operator-attention control plane** — a scheduler whose unit of work is "a human decision." Claude calls it "an attention queue with attribution," Codex calls it "an attention control plane" with four layers (truth / policy / projection / delivery), Gemini calls it "an Agent Exception Handling Protocol" and maps it directly onto OS primitives (`suppressed` = backgrounding, `flag` = an unhandled exception awaiting a signal). Three different vocabularies, one conclusion: name the layer, because naming it changes cheap decisions you are about to make and would otherwise pay for later.

2. **The single highest-leverage, lowest-cost change is the event payload.** All three reviews converge here, and it is the only place where all three independently used the word "invest" or equivalent. The events are a published v1 surface (`spec/event-envelope.v1.schema.json`, `skills/c11/references/events.md`) with external consumers within a week. Everything else in the ticket is internal and revisable; the event schema is not. Enrich `flag.raised` and `flag.lowered` **before writing any handler code**.

3. **The second convergence is a reply/resolution channel.** All three note that a flag is posed as a *question* ("Need a call on schema migration vs dual-write") but answered with a *one-bit acknowledgement* (`by: operator | agent`). Claude and Codex frame this as breaking the calibration flywheel; Gemini frames it as discarding a training-data asset. The fix all three land on is the same: an optional `resolution` / `note` field on lower.

4. **The third convergence is that suppression is dangerously invisible and needs an audit surface.** Claude names the failure mode precisely (an orchestrator launches thirty suppressed children and dies; thirty surfaces are permanently and silently muted, and the sidebar quietly stops being a true picture of the fleet). Gemini reaches the same place from operator psychology ("humans are notoriously bad at remembering they muted something") and proposes time-bound suppression. Codex reaches it from architecture (suppression should mean *routed*, not *invisible*). This is the feature's monotonic decay vector and the reviews treat it as a v1 concern, not a nicety.

5. **The reviews diverge productively on sequencing.** Claude wants a **horizontal** split (PR 1 = phases 0–3, primitives + events, zero pixels; PR 2 = renderers + latency gate), arguing a visual ship blocker should not strand a primitive that Overwatch, cron, and the Lattice orchestrator can consume unchanged. Codex wants a **vertical** split (walking skeleton: prove the attention kernel, then one end-to-end slice, then fan out ingress). These are compatible and arguably should be combined: Codex's kernel-first discipline *inside* Claude's PR 1.

6. **Only one hard design collision was found, and only by one reviewer.** Claude identified that a mission-scoped flag (`launch-agent --flag`, explicitly supported, "violet for its lifetime") produces a banner permanently obscuring live terminal output, whose only dismissal path (`lower`) destroys the mission-scope intent the flag was expressing. This needs deciding in the plan, not discovered in Phase 5.

7. **Codex found the deepest correctness bug:** `SurfaceMetadataStore` stamps a new `SourceRecord.ts` whenever a value changes. An active-flag reason revision *is* a changed value. So the plan's carefully-specified "preserve the original queue epoch across revision" holds in memory but **silently breaks across relaunch** — the restored flag carries the revised timestamp and jumps its queue position. This is a real defect in a specified behavior, and no other reviewer caught it.

---

## 1. Consensus Direction — Evolution Paths Multiple Models Identified

### 1.1 This is an attention control plane, not a UI feature (3/3)

All three arrived here independently and it should be stated in the ticket.

| Model | Framing |
|---|---|
| Claude | Layer 3: "an attention queue with attribution" — `flag.list` is the queue read, Option-V is the pop, Overwatch tailing `flag.raised` is the second consumer, arriving free |
| Codex | Four layers: operational truth → attention policy → attention projection → attention delivery. "Who is owed attention, why, in what order, and through which channel?" |
| Gemini | "Agent Exception Handling Protocol" — the first step toward a true OS scheduler for autonomous agents |

**Practical consequence all three draw:** keep the service, event envelope, and query scope free of the assumption that the operator is the only possible sink.

### 1.2 The event payload is the compounding lever (3/3)

- **Claude:** "An extra hour on `flag.raised` and `flag.lowered` payloads is the highest-return hour in the ticket." Wants `task`, `role`, `title` so a consumer can *route* rather than merely *watch* — otherwise fleet-scale triage costs a socket round-trip per flag, possibly cross-instance.
- **Codex:** treat `flag.list` + events as an explicit **snapshot-plus-delta protocol**, and document how a consumer recovers after a dropped event or restart.
- **Gemini:** "If those events are rich enough, the community will build the dashboards and auto-resolvers for you." Wants terminal-buffer context in the payload.

### 1.3 The lower needs a resolution, not just an author (3/3)

The convergence is exact, with three different justifications:
- **Claude:** the skill instructs agents to make a real re-raise decision on the outcome signal; that decision is not computable from one bit. `resolution: answered | deferred | resolved`.
- **Codex:** "attention receipts" — lets an agent know whether to remain blocked, continue elsewhere, or re-raise with new information. Treat lowering attribution as *protocol*, not decoration.
- **Gemini:** `--resolution <text>` builds a high-value dataset for agent self-correction; costs almost nothing to store.

### 1.4 Suppression must not be invisible-and-permanent (3/3)

- **Claude:** make `flag.list` an **attention list** returning active flags *and* suppressed surfaces (`suppressed_at`, `suppressed_by`). Same handler, same commit boundary, one more array. Also: record the suppressing surface so a later sweep can find orphans.
- **Gemini:** **ephemeral suppression** — `suppress --until 1h` or `--until-flag`. Permanent suppression risks zombie agents burning resources.
- **Codex:** the evolution of a Boolean `suppressed` is not "more levels," it is **attention ownership** — suppressed work should be quiet to the *operator* but not invisible to its *supervisor*.

### 1.5 Overwatch/supervisor agents are the real scaling answer (3/3)

All three land on the same architecture: flags should be triaged by the cheapest competent attention, which is usually another agent, not the human.
- **Claude:** "half of real blockers are 'which of these two' questions an agent with fleet context can settle." Explicitly notes this mutation is what *justifies* the payload-enrichment, reply-channel, and resolution-attribution suggestions — without them a triage agent can observe but not act.
- **Codex:** routed suppression with `attention_route` / `supervisor_surface`; pluggable attention sinks.
- **Gemini:** "The Supervisor Swarm" — reads the event, injects the missing GitHub token, lowers the flag. The human never sees it.

### 1.6 Instrument the feature's own calibration (3/3)

- **Claude:** flags per agent-hour, answered-vs-deferred ratio, mean time-to-lower, flag rate by role. "None of that is knowable today."
- **Codex:** time-to-focus, time-to-lower, re-raises after dismissal, suppressed completions, flags that never caused a stop. Explicitly: *exclude or redact reason text from aggregate analysis.*
- **Gemini:** MTBI (Mean Time Between Interventions) as the headline autonomy metric.

All three add the same guardrail: **measure, do not enforce.** No rate limits, no quotas. Scarcity stays social.

---

## 2. Best Concrete Suggestions — Most Actionable Across All Three

Ordered by value per unit of effort. Model attribution in brackets.

1. **Enrich both flag event payloads before writing any handler code.** [C, X, G]
   `flag.raised { reason, raised_at, revision, task?, role?, title? }`
   `flag.lowered { by, resolution, note? }`
   Cost: about an hour plus the schema file and `references/events.md`. Value: unblocks Overwatch triage, cron escalation, the Lattice bridge, and the calibration flywheel — and avoids a v1 schema break. **Do this first.**

2. **Fix the flag-epoch persistence defect.** [X]
   `SurfaceMetadataStore` re-stamps `SourceRecord.ts` on any value change, so an active-to-active reason revision loses its original queue age across relaunch. Persist a paired `flag_since` / `flag_epoch` alongside the reason (cleaner: "last write time" and "attention epoch start" are genuinely different facts), or add a narrowly scoped epoch-preserving store primitive. Test: raise A → revise to B → snapshot → restore → assert age and queue position unchanged.

3. **Make the raise observable as a revision on the wire.** [C]
   `flag.raised` currently carries no epoch, so a consumer sees two raises for one surface and cannot tell that the queue age did not reset. A cron escalation firing on "flag up for an hour" is reset by every revision. This is an external-contract defect on a published surface, not a nit. Covered by suggestion 1's `raised_at` + `revision`.

4. **Make `flag.list` an attention list including suppressed surfaces.** [C, with G/X support]
   One additional array carrying refs, `suppressed_at`, `suppressed_by`. It is the only counterweight to a deliberately invisible state, and the only mechanism that stops the sidebar from quietly becoming untruthful.

5. **Split state commit from side-effect delivery.** [X]
   `SurfaceAttentionService` should own one serialized *state transition*; it must not claim atomicity with `UNUserNotificationCenter` or custom delivery commands, which cannot participate in that boundary.
   - **Commit:** validate → mutate canonical metadata → publish snapshot → rebuild eligibility → emit event → return a stable `AttentionTransitionResult`.
   - **Effects:** schedule/remove notifications and invoke transports with an idempotency key derived from surface + flag epoch.
   If delivery fails, the flag stays raised; the socket response reports `delivery: scheduled | disabled | failed` without rolling back canonical truth. This also creates the reusable delivery seam for future transports.

6. **Split the ticket at the Phase 3/4 boundary.** [C]
   PR 1 = canonical metadata, attention service + commit boundary, socket methods, CLI, launch flags, raw/signal index split, waiting edges, notification delivery, oldest-first navigation, all four events, `flag.list`. Zero rendering, zero Bonsplit, zero submodule pointer commit, zero latency gate.
   PR 2 = both renderers, motion policy split, Flagged Agents row, banner, fleet-latency gate, tagged visual evidence.
   PR 1's output (a live event stream with real flags) becomes PR 2's *input* for tuning the violet — matching the operator's stated method of dialling motion in a tagged build. And a latency failure in PR 2 cannot strand the primitive.

7. **Correct the latency baseline and shrink the matrix.** [C]
   The plan gates on "feature-on p95 delta vs the **static** baseline ≤ 1 ms," but base motion shipped in C11-183 (`29102376f`) and is on by default. Measuring against static charges C11-184 for C11-183's cost — and two of the three fallback rungs ("disable stepped fill by default," "ship base marks static") are reversals of a shipped, separately-decided default. That is C11-183 rework wearing a C11-184 mitigation label, surfacing at the worst moment.
   - **C11-184's gate:** HEAD-with-flags vs HEAD-without-flags, *both with base motion at shipped default*, at a pessimistic flag population (5 of 20; the design target is ≤1 in 10). One fallback rung: "flags ship static violet."
   - **C11-183's regression check:** static vs shipped default, run once, reported as an *observation* feeding a separate follow-up ticket.
   Collapses five configurations to two and the ladder to one rung.

8. **Resolve the mission-flag banner collision, in the plan.** [C]
   A flag scoped to a whole mission (`launch-agent --flag`) yields a banner permanently over live terminal pixels for the mission's lifetime, dismissable only by lowering the flag — which destroys the intent. Preferred fix: **collapse-without-lower** (chevron shrinks the banner to a small violet glyph; flag stays up; state persists per-surface) alongside the X. Alternatives: auto-collapse after first view; launch-time flags render collapsed by default (weakest — creates two flag classes, contradicting the one-tier framing). Decide now: it affects the banner state model, persistence across restore, two localized strings, and the accessibility contract.

9. **Promote the flag reason into a value type.** [X]
   One `FlagReason` parser/normalizer shared by the socket family, generic metadata mutations, launch flags, restore, and tests. Beyond blank/multiline/length: define handling of `\r`, Unicode line separators, NUL and control characters; whether the 256 cap is graphemes or UTF-8 bytes; trimming/normalization; and **privacy guidance**, since the reason lands in snapshots, the event log, Notification Center, and custom delivery commands. Safer and simpler than re-implementing validation at every ingress.

10. **Give the signal-eligibility builder a policy-struct parameter.** [C]
    `eligibility(for: notification, policy: AttentionSignalPolicy)` rather than an inline suppression read — even if the struct has exactly one field today. This is the seam that later carries do-not-disturb, quiet hours, per-workspace mute, focus modes, digests, and role filters at near-zero marginal cost. The plan builds ~90% of fleet-wide DND without noticing.

11. **Model three notification views, not two.** [X]
    Raw history / current in-app demand eligibility / edge-triggered delivery receipt. This is what makes unsuppress deterministic: an unsuppressed unread record should re-enter counts, Option-V, and waiting edges **without replaying a desktop notification that was intentionally suppressed when created.** Two views make "eligible now" accidentally mean "deliver externally now."

12. **Specify direct-notification lifecycle and identity.** [X]
    A stable notification identifier keyed on surface + flag epoch. Reason revision *replaces* rather than duplicates. Lower/close/prune removes both pending and delivered requests. A click after transfer resolves by stable surface ID, not a stale embedded workspace ID. A click after close fails closed. Add race tests.

13. **Decide suppression batching and launch inheritance explicitly.** [C]
    The headline use case (orchestrator with subagents) currently requires N calls to suppress an existing fleet. At minimum accept repeated `--surface` refs on suppress/unsuppress (preserves the C11-165 no-focused-fallback policy — still no implicit target). Separately decide whether an agent-originated `launch-agent` from a suppressed surface defaults the child to suppressed. **Either answer is defensible; deciding by omission is not** — retrofitting inheritance after agents script against non-inheriting behavior is a behavior break.

14. **Pin the breathe waveform numerically.** [X]
    The binary flash is exact; the breathe is not. Define duration, opacity envelope, easing, and phase behavior once in the shared sampler so Bonsplit and the sidebar cannot drift. Keep all four motion samplers in the shared generic clock module. Static fallback stays pre-registered.

15. **Name the banner host and the Bonsplit token generically.** [C]
    `SurfaceOverlayBanner` with a flag *content* variant, with the z-order matrix written as a property of the host rather than of flags. The z-order contract (against find, pane interaction, copy badge, notification ring, flash) is expensive to derive and reusable forever; the obvious next consumers are mailbox previews, CI/build status, resume-session prompts, and degraded-connection warnings. Separately, let the Bonsplit presentation value carry an **opaque host-defined token** alongside color and motion channel, so future c11 semantics need zero Bonsplit changes and zero submodule round-trips.

16. **Land the generic Bonsplit seam as a separate, prior commit.** [X]
    Ideally reviewed before the c11 feature wiring, so the parent feature *consumes* a stable generic seam instead of developing submodule API and product policy simultaneously.

17. **Ship the operator-held Phase 3 decision as a `UserDefaults` key, not a compile-time branch.** [C]
    Default "no direct delivery on suppressed surfaces," per spec. The branch already exists; making it a default turns a blocking decision into an empirical one the operator can settle over a week of overnight sweeps.

18. **Reconcile the staged skill text against the Phase 4 motion outcome.** [C]
    `docs/c11-attention-model-skill-section.md` asserts "if you are also stopped, the mark **strobes**" — which the static-violet fallback rung falsifies without changing any command contract. Phase 6 says copy the section "exactly, adjusting only if a *command contract* changed." Add one reconciliation step, and do it before the six-locale translator stage runs (the existing ordering already protects you if it's remembered).

19. **Add an authoritative attention transition table.** [X]
    Old state × command → new state, event, waiting edge, delivery intent, idempotency result. Covers every lifecycle × flag × suppression combination.

20. **Add downgrade/restore coverage.** [X]
    An older build must preserve unknown attention metadata; a new build must rehydrate it without queue-age loss.

21. **Make scope a first-class internal query parameter.** [X]
    "App/window-global" is too ambiguous for an index that may outlive one window. Internally accept explicit scope (active window / workspace set / process-wide) and define `flag.list`, the Flagged Agents count, and Option-V against the same scope object and the same deterministic ordering implementation — even if v1 exposes only current behavior.

22. **Expose debug-only clock subscriber counts and transition traces before the expensive fleet validation.** [X]
    Turns the fallback ladder into a quick decision rather than a late forensic exercise.

---

## 3. Wildest Mutations

Ranked roughly by ambition. Most are explicitly not-v1; the point of listing them is that several cost *nothing today* if the payloads and seams are shaped correctly.

1. **The Supervisor Swarm / Overwatch as triage, not observer.** [G, C, X]
   The most-agreed wild idea. A standing agent tails `flag.raised`, reads the reason, and either answers directly (via mailbox) or escalates to the operator with other flags batched. Gemini's example is concrete: worker flags "Need a GitHub token" → supervisor injects it → lowers the flag → human never sees it. Claude notes this converts flags from *operator attention* to *the cheapest competent attention*, which is the actual scaling answer past thirty agents. **Gated entirely on payload richness and a reply channel** — without them a triage agent can observe but not act.

2. **Flag replies over the existing mailbox transport.** [C]
   `Sources/Mailbox/` is already a complete inter-agent messaging system: addressing (`MailboxAddress`, `MailboxSurfaceResolver`), dispatch log, delivery events, size cap, cross-workspace ambiguity resolution, and a `c11 mailbox send` CLI. The transport for *answering* a flag already exists and is already tested. v2 shape: banner X **plus** a reply field that dispatches a mailbox envelope to the flagging surface and lowers with `resolution: answered`. **The payoff is a category change, not an increment: operator throughput goes from acknowledging a blocked agent to unblocking one.**

3. **Terminal-context in the raise payload.** [G]
   `flag.raised` carrying the last N lines of the surface buffer, the last executed command, or the CWD — so triage (human or agent) happens without a focus switch. The most operationally aggressive suggestion in any review, and the one with the sharpest privacy tension against Codex's redaction guidance (#9, #14).

4. **The automated training-data factory.** [G]
   The full flywheel: flag + resolution + *the commands typed between them* become a paired (problem, solution) record. Gemini: "If the UI could automatically snapshot the 5 commands typed between a `flag` and a `lower`, you'd have an automated training-data factory." Highly ambitious, obvious privacy weight, and it makes the case for the `resolution` field far beyond its immediate UX value.

5. **Routed suppression / attention ownership.** [X]
   `worker completion → supervising orchestrator`, `worker flag → operator (or supervisor, then operator)`, `orchestrator done → operator`. The v1 Boolean survives as shorthand for "not the operator's routine queue." Solves the real orchestrator problem: suppressed work should be quiet to the operator but **not invisible to its supervisor**. Explicitly not v1 — but it should shape internal naming now.

6. **Invert the default.** [C]
   If nine in ten agents should never flag, and the headline shape is a suppressed subtree, arguably **silence should be the default for agent-launched surfaces and signal should be opt-in**. The plan builds all the machinery for that world and ships the opposite default. Not a v1 recommendation — but the answer determines whether launch inheritance is a convenience or the actual intended model.

7. **Deferred / batched flags — attention batching instead of attention interruption.** [C]
   `raise-flag --not-before <when>` or `--batch`. An agent needing a human decision but not urgently queues for the next sweep instead of firing a system notification. A genuinely different product philosophy, and probably the correct one at fleet scale where interrupt cost dominates. **The data model already supports it: a flag with a raise epoch and a queue is one timestamp field from a scheduled queue.**

8. **The flag bidding market.** [G]
   Severity or "bounty" on flags instead of strict oldest-first FIFO; critical infrastructure agents outbid coding agents for operator attention. The most contrarian idea in the pack — it directly contradicts the plan's deliberate one-tier design and the "no priority levels" stance. Worth one round of thought precisely because it's the road not taken.

9. **Flag storm coalescence.** [G]
   A backend outage makes 50 agents flag simultaneously. Detect identical or near-identical reasons, coalesce into a single "Incident," support bulk-lowering. Pairs with Gemini's throttling question — nothing in the plan currently bounds the system-notification rate under correlated failure.

10. **Pluggable attention sinks.** [X]
    Once delivery is separated from the state transaction, the same transition feeds macOS notifications, a custom command, Overwatch, a future mobile/remote relay, and an audit-only sink for overnight runs. The core emits one idempotent delivery *intent*; transports decide whether and how to render it. Note the mobile/tailnet relay implication: an operator away from the machine could still be reached by a genuinely blocked agent.

11. **Opacity as age.** [C]
    Opacity is explicitly unspent in both design docs. The plan correctly rejects age-based visual escalation for v1 (flags do not decay). But when fifteen flags are up, "which has been starving longest" is exactly the question the queue answers and the UI does not. Cheapest version: nothing in the mark, and a relative-age string in the Flagged Agents row. A v1.1 the queue epoch already enables.

12. **Flag-to-Lattice bridge.** [C]
    A flagged delegator *is* structurally a blocked ticket. `flag.raised` on a surface whose worktree metadata maps to a Lattice task becomes a comment or status transition; `flag.lowered { resolution }` closes it. This unifies the c11 attention model with the lattice-orchestrator workflow — the dominant use of c11 in this shop. **Requires exactly two things from this ticket: enriched raise payloads and resolution attribution on lower — both already recommended for independent reasons.** That convergence is a good sign.

13. **Attribution vocabulary across all metadata.** [C]
    `by: operator | agent` is the first time c11 records *who* made a metadata assertion. Extending that to `status`, `task`, and `progress` is one enum away, and it is the missing half of the existing source-precedence chain (`explicit > declare > osc > heuristic` tells you the tier, not the author).

14. **Suppression auto-clears on flag raise.** [G]
    Not just "flag visually overrides suppression" — actually *clear* `suppressed` when a flag is raised, fully demoting the agent back to normal operator attention. Small, opinionated, and it would sidestep the entire Phase 3 operator-held decision. Note it also collides with the plan's core orthogonality commitment, so it is a real fork rather than a tweak.

---

## 4. Flywheel Opportunities

### 4.1 The calibration flywheel — stated by the plan, not closed by it [C, X]

The plan's regulation mechanism for flag scarcity is social: "an agent that interrupts for nothing gets told so." No enforcement, no rate limit — correct. **But that loop only turns if the agent observes the outcome of its flag, and today the entire observable outcome is one bit.** An agent that flags well and an agent that flags badly receive an identical signal.

```
flags are rare  ->  flags are trusted  ->  operator answers fast
      ^                                            |
      |                                            v
agents calibrate  <-  agents observe outcomes  <-  outcome is recorded
                             ^
                             |
                    (this arrow is one bit wide)
```

**Engineering move:** widen the arrow with `resolution` (suggestion 1) and, later, a reply channel (mutation 2). With both, the skill's re-raise guidance becomes a real decision procedure rather than an exhortation. Codex's parallel framing: typed attention state → deterministic events → better orchestration and measurement → evidence-backed skill guidance → cleaner agent behavior → higher-quality attention state.

### 4.2 The triage flywheel — the one that scales past thirty agents [C, G]

```
flags emit rich events  ->  Overwatch triages  ->  fewer flags reach the operator
        ^                                                       |
        |                                                       v
agents flag more freely  <-  operator tolerance for flags rises  <-
```

**Entirely gated on the raise payload carrying enough context to route on.** This is the strongest single argument for suggestion 1.

### 4.3 The self-correction / training-data flywheel [G]

```
1. Agent hits a novel problem            -> raises flag
2. Human investigates, solves, lowers    -> with a resolution note
3. Flag + resolution ingested into context or a fine-tuning corpus
4. Agent hits the same problem           -> solves it autonomously, no flag
```

**Engineering move:** link the `lower` action to the preceding terminal input. Carries obvious privacy weight (see Codex's redaction guidance) but explains why `--resolution` is worth far more than its immediate UX value.

### 4.4 The product flywheel the plan already intends [X]

```
suppressed routine work -> less operator noise -> flags remain rare and trusted
-> operator responds faster to real blockers -> agents learn precise flags work
-> better reasons and more disciplined suppression -> (loop)
```

**To start it:** preserve signal scarcity, and record enough non-sensitive timing evidence to distinguish useful flags from noisy ones. **Do not add enforcement before real data exists.** (All three reviews independently reach this same "measure, don't enforce" position.)

### 4.5 The anti-flywheel to watch [C]

Suppression is invisible, permanent, per-surface, and has no audit surface. **Every forgotten suppression makes the sidebar a slightly less complete picture of the fleet. The degradation is silent by construction and compounds monotonically. Nothing in the plan reverses it.** This is the strongest independent argument for treating "make `flag.list` an attention list" (suggestion 4) as a v1 *requirement* rather than a nicety: it is the only brake on the one mechanism in this feature that can quietly make the sidebar lie.

---

## 5. Strategic Questions for the Plan Author

Deduplicated and merged across all three reviews. Model attribution in brackets.

### Protocol and semantics

1. **Is a flag a notification or a question?** The reason string, the required-not-optional rule, and the motivating example all say *question*. The reply vocabulary (one X) says *notification*. Which is it in v1 — and if it is a notification in v1 and a question in v2, are you willing to spend the two optional payload fields now to keep v2 non-breaking? [C]

2. **What is the intended relationship between flags and the existing mailbox system?** Two agent-to-human/agent channels that currently do not know about each other. Is flag-plus-mailbox-reply the roadmap, or are they deliberately separate concerns? [C]

3. **Is `by: operator` an authenticated fact or caller-supplied attribution?** A socket field available to every local agent is not, by itself, proof the operator acted. Which paths are actually trusted to set it — and if socket callers may supply it, will you document it as *claimed* attribution rather than a security boundary? [X]

4. **Should an agent be permitted to lower its own flag?** The spec says "no auto-lower on terminal input," but what if the agent realizes it can recover? Is self-lower allowed, and does it emit a distinguishable resolution? [G]

5. **May flag reasons contain sensitive project details?** What guidance or redaction is required, given the reason reaches lock-screen notifications, the event log, snapshots, and custom delivery commands? [X]

### Persistence and correctness

6. **What is the canonical persisted representation of the original flag epoch after an active reason revision?** `SurfaceMetadataStore` re-stamps `SourceRecord.ts` on any value change, so oldest-first queue order silently changes after restart unless a separate epoch is persisted. Which solution — a paired `flag_since` value, or an epoch-preserving store primitive? [X]

7. **Should a socket mutation succeed when canonical state commits but system delivery fails, and what delivery outcome should the response expose?** [X]

8. **On lower, close, or prune, should c11 remove the flag's already-delivered Notification Center entry as well as pending requests?** [X]

9. **When an unread suppressed surface is unsuppressed, should it only re-enter the in-app queue, or also receive retroactive desktop delivery?** [X]

10. **Should a direct notification click resolve a transferred surface by stable surface ID when the embedded workspace ID is stale?** [X]

### Scope, defaults, and ergonomics

11. **What is the audit story for suppression?** Given suppression is deliberately invisible — no badge, no dim, no distinguishable mark — how does the operator answer "what have I muted?" a week later? If the answer is `get-metadata` per surface, is that acceptable at thirty surfaces? [C, G]

12. **Is permanent suppression the right model, or should it support a timeout / condition?** `suppress --until 1h`, `--until-flag`. Humans forget what they muted; zombie agents burn resources. [G]

13. **Does `launch-agent` from a suppressed agent surface inherit suppression?** The orchestrator/subagent shape is named as the primary use case in three documents. Inheritance makes it one rule; non-inheritance makes it N calls. Either is defensible — **but the decision should not be made by omission**, because retrofitting is a behavior break. [C]

14. **Is silence the right default at fleet scale?** If nine in ten agents should never flag and the headline shape is a suppressed subtree, should agent-launched surfaces default to suppressed and opt into signalling? Not a v1 change — but the answer determines whether Q13 is a convenience or the actual model. [C]

15. **Does the eventual orchestration model want suppression to mean "no operator signal" or "route routine signals to my supervisor"?** The answer should shape internal naming even if v1 stays Boolean. [X]

16. **Is `flag.list` scoped to one window, all workspaces in the process, or the caller's workspace by default?** [X]

### Sequencing and risk

17. **Will you split at Phase 3/4?** Specifically: is there a reason the primitive and event layer must ship in the same PR as the renderers, *other than* the skill text asserting visual behavior? If the skill text is the only coupling, would you soften two clauses to decouple them? [C]

18. **Should the latency gate's fallback ladder be allowed to change a C11-183 default?** Two of the three rungs reverse a shipped, separately-decided motion default. Is that in C11-184's remit, or should the ladder be restricted to the flag rung? [C]

19. **Can the generic Bonsplit presentation seam land as a prerequisite submodule change**, so the feature PR consumes rather than invents that API? [X]

### Visual and UX contracts

20. **What happens to the banner on an operator-set, mission-scoped flag?** A permanently-visible banner over live TUI output for the mission's lifetime, dismissable only by destroying the flag, is the current specification. Is that intended — and if not, is collapse-without-lower in scope for v1? [C]

21. **When the operator lowers via the banner X, should the banner offer a quick way to log the resolution?** Otherwise the reason for dismissal is lost at exactly the moment it is cheapest to capture. [G]

22. **What exact duration, opacity envelope, and easing define the flag breathe?** [X]

23. **What is the second consumer of the surface overlay band?** If you can name one (mailbox previews, CI status, resume prompts), that alone justifies building the host generically in Phase 5 rather than refactoring it out later. [C]

### Scale and measurement

24. **Are you at risk of a flag storm** — a network outage causing 50 agents to flag simultaneously — and is there any throttling on direct system notifications? [G]

25. **If a supervisor agent listens to `flag.raised` and fixes the issue, how does it know the context** without terminal state in the event payload? [G]

26. **How will you know, three months in, whether the attention model is calibrated?** Flags per agent-hour, answered-vs-deferred ratio, mean time-to-lower, flag rate by role, MTBI, lower scan time — all derivable from the event stream *if the payloads carry enough*. Is measuring the feature's own calibration a goal, and does the current payload support it? [C, X, G]

---

## Appendix: Where the Plan Is Already Strong (consensus)

Stated plainly, because nearly everything above is additive rather than corrective. All three reviewers described the plan as unusually complete and directionally right.

1. **The raw-history / signal-eligibility index split** is called the most reusable thing in the ticket [C] and an essential foundation [X].
2. **Flag and suppression as strictly orthogonal modifiers** — resisting the pull toward a priority hierarchy. [X]
3. **The serialized attention-commit service with explicit commit-before-response ordering**, plus closure of every generic-metadata bypass (set, clear, replace, restore, launch, transfer, close, prune) with adversarial coverage — "the kind of thing usually discovered in review rather than specified in the plan." [C]
4. **Active-to-active revision semantics** (preserve epoch, no second queue entry, no age reset) — precise, and exactly the sort of detail that produces a real bug if left implicit. Gaps are that it is unobservable on the wire [C] and not durable across relaunch [X].
5. **Keeping the Bonsplit seam generic** and naming upstream candidacy without opening the upstream PR during the task — correct under the repo's bidirectional-upstream policy. [C, X]
6. **Isolating the operator-held Phase 3 decision to a single call-site branch**, with an explicit statement that nothing else may depend on it — a model for deferring a policy question without stalling implementation. [C]
7. **Splitting base-motion permission from explicit-motion permission** rather than overloading the existing single boolean — and correctly framing it as a change to the *generic* host policy rather than a c11-specific hack. [C]
8. **Submodule detached-HEAD prevention, single tagged launch with recorded bundle/PID/socket, CI-as-sole-test-executor** — all encode real prior pain in this repo. [C]
9. **Deferring the cross-workspace dashboard** and letting `flag.list` plus events serve external aggregation until usage patterns are proven. [G]

---

## Appendix: Note on One Unresolved Contradiction

Codex flags a **binding-spec conflict** that should be reconciled before implementation: `docs/c11-flagged-agent-plan.md` says suppressed surfaces deliver no system notification, while the authoritative Phase 3 decision has a direct flag notification piercing suppression. Codex proposes a "Phase -1 — reconcile contracts" step before any code: amend the plan doc and the staged skill section so routine suppression and flag escalation agree everywhere, freeze the socket schemas, and choose the epoch representation.

Claude reaches the same territory from the other side (suggestion 17: ship the decision as a `UserDefaults` key rather than a compile-time branch), which would let the contradiction be resolved empirically rather than in advance. **These two answers are not compatible.** Either the spec is amended to a single authoritative position, or the divergence is made a runtime default — but the docs cannot be left disagreeing.
