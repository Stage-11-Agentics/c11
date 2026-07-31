# TP-c11-184-plan-Claude-Evolutionary-20260728-1726

Evolutionary plan review of `.lattice/plans/task_01KYMTXQVWCXCF0TGN5ZWG341E.md` (C11-184: flagged and suppressed agents), read against `docs/c11-flagged-agent-plan.md`, `docs/c11-attention-model-skill-section.md`, `docs/c11-mark-vocabulary.md`, the repo `CLAUDE.md`, and the shipped seams at HEAD (`Sources/Sidebar/SidebarActivityProjector.swift`, `Sources/SurfaceMetadataStore.swift`, `Sources/TerminalNotificationStore.swift`, `Sources/Events/`, `Sources/Mailbox/`).

---

## Executive Summary

This is a strong, unusually executable plan. The seam audit is real, the threading and focus contracts are correct, the operator-held Phase 3 decision is properly isolated, and the submodule/skill-sync/tagged-build discipline is all present. Most of what follows is not correction. It is about what the plan is quietly building and is not yet claiming.

The biggest opportunity: **C11-184 is not a pair of visual modifiers. It is c11's first attention-scheduling API, and its first genuinely two-way protocol between an agent and its operator.** Everything before this was one-directional: agents pushed telemetry (`status`, `task`, `progress`, `activity`), and the operator pushed keystrokes and mailbox envelopes. A flag is the first construct where an agent makes a *persistent, addressable, timestamped claim on operator attention* and the operator's response is *recorded and returned to the agent*. That handshake is currently one bit wide (`by: operator | agent`). Widening it slightly, right now, while the schema is still unpublished, is the single highest-leverage change available.

The second-biggest: **split the ticket at the Phase 3/Phase 4 boundary.** Phases 0 to 3 constitute a complete, shippable, externally consumable product with zero rendering risk and zero Bonsplit submodule exposure. Phases 4 to 5 carry the fleet-scale latency gate, which is explicitly a hard ship blocker with a fallback ladder that can degrade all the way to "static violet." As currently structured, a latency failure in a decoration blocks a primitive that Overwatch, cron escalation, and the Lattice orchestrator workflow can all consume without a single pixel changing.

The third: **the plan builds an audit surface for flags (`flag.list`) and none for suppression**, despite suppression being, by explicit design, completely invisible. That asymmetry is the feature's long-term decay vector.

---

## What's Really Being Built

Three layers, only the top one of which the plan names.

**Layer 1 (stated): two orthogonal persisted modifiers over the four-state lifecycle.** Violet marks, a sidebar row, a banner, a notification. This is the deliverable.

**Layer 2 (implicit): a signal-eligibility predicate distinct from unread-ness.** The refactor of `TerminalNotificationStore.NotificationIndexes` into raw-history and signal-eligible views is the most reusable thing in the ticket. Right now the eligibility input happens to be `!(suppressed && !flagged)`. The moment that predicate exists as a pure function over an input struct rather than as an inline read of suppression, c11 gains: do-not-disturb, quiet hours, per-workspace mute, focus modes, notification digests, and "only signal me for surfaces whose role is orchestrator." Each of those is roughly one additional field on the eligibility input. The plan builds this and does not notice it is building it.

**Layer 3 (unnamed): an attention queue with attribution.** A per-surface record carrying a reason, an original raise epoch, an author (`operator | agent`), a deterministic oldest-first ordering, and four event types on a documented external stream. That is not a UI modifier. That is a work queue whose unit of work is "a human decision," and c11 is now the scheduler for it. `flag.list` is the queue read. Option-V is the pop. Overwatch tailing `flag.raised` is the queue's second consumer, and it arrives for free.

Name Layer 3 in the ticket, because naming it changes decisions you are about to make cheaply and would otherwise pay for later (event payload shape, the `by` vocabulary, whether suppression is queryable).

There is also a fourth artifact hiding in Phase 5: **a non-layout-participating, AppKit-portal-owned, top-edge overlay host with a fully specified z-order contract against find, pane interaction, copy badge, notification ring, and flash.** That z-order matrix is expensive to derive and reusable forever. The plan builds it as `SurfaceFlagBanner`, a one-off.

---

## How It Could Be Better

### 1. The flag is a question with no answer channel, and c11 already ships the answer channel

The motivating example throughout is "Need a call on schema migration vs dual-write." The operator's entire reply vocabulary is an X that means "lowered, by operator." The spec itself flags the ambiguity: an agent cannot distinguish *seen and deferred* from *nobody looked* without `by`, and even with `by` it cannot distinguish *answered* from *dismissed unread*.

Meanwhile `Sources/Mailbox/` is a complete inter-agent messaging system with addressing (`MailboxAddress`, `MailboxSurfaceResolver`), a dispatch log, delivery events (`mailbox.accepted`, `mailbox.delivered`), a size cap, ambiguity resolution across workspaces, and a `c11 mailbox send` CLI. The transport for answering a flag already exists and is already tested.

This does not have to be built in C11-184. But the banner and the event schema should be shaped so it is a small addition rather than a schema break:

- Give the banner a second affordance slot from day one, even if v1 renders only the X.
- Add an optional `note: String?` to the `flag.lowered` payload. One optional field now; a schema v1 amendment plus CLI, socket, skill, and six locales later.
- Sketch, in the plan's non-goals, what the v2 looks like: banner X plus a reply field that dispatches a mailbox envelope to the flagging surface and lowers with `resolution: answered`. Naming it as deliberate v2 is different from not having thought of it.

The payoff is a category change, not an increment: the unit of operator throughput goes from *acknowledging* a blocked agent to *unblocking* one.

### 2. `by` is one bit where three are nearly free

`flag.lowered { by: "operator" | "agent" }` is the agent's only outcome signal, and the skill section instructs agents to make a real decision on it ("Re-raise only if the blocker still stands and you can say why the deferral does not"). That decision is not computable from one bit.

Propose a second payload field, set by which affordance was used:

```
flag.lowered  payload: { by: "operator" | "agent", resolution: "answered" | "deferred" | "resolved" }
```

Even shipping only `deferred` (banner X) and `resolved` (agent lower) is strictly more information than today, costs one enum, and makes the skill's re-raise guidance actually actionable. This is the field that closes the feature's flywheel (see below).

### 3. An active-to-active revision is indistinguishable from a fresh raise on the wire

The plan is careful and correct internally: a reason revision preserves the original queue epoch and emits one new `flag.raised`. But `flag.raised { reason }` carries no epoch. A consumer tailing the events stream (which is the entire stated Overwatch integration story, and the plan's answer to "no cross-workspace dashboard") sees two `flag.raised` events for one surface and has no way to know the queue age did not reset. A cron escalation that fires on "flag up for an hour" will be reset by every revision.

This is a genuine external-contract defect, not a nit, because `spec/event-envelope.v1.schema.json` and `skills/c11/references/events.md` are published surfaces.

Fix: `flag.raised payload: { reason, raised_at, revision: Bool }` (or `raised_at` alone, which implies it). Cheap now, breaking later.

### 4. The `flag.raised` payload should carry enough context to triage without three follow-up calls

If the events stream is the Overwatch integration, a triage consumer receiving `flag.raised { reason }` on `surface: <uuid>` must then call back for the surface title, its `role`, its `task`, and its workspace name in order to decide anything. At fleet scale that is a round-trip per flag against a socket that may belong to a different instance.

Include the surface's `task` and `role` (and the resolved surface title) in the raise payload, captured at raise time. This is the difference between "an event stream you can watch" and "an event stream you can route on." It also makes the flag-to-Lattice bridge (a blocked agent becoming a blocked ticket comment) a twenty-line script instead of a project.

### 5. Suppression has no audit surface, and that is its decay vector

By deliberate design, suppression has no tint, no dim, no badge, no label, and no distinguishable mark. The stated record of the modifier is "the operator's knowledge of what they dispatched, plus `get-metadata`." The plan ships `flag.list` and no suppression equivalent.

Consider the failure mode: an orchestrator launches thirty suppressed children and dies. Those thirty surfaces are now permanently and invisibly muted. They read idle whether they finished, stalled, or crashed. There is no sidebar affordance, no count, no row, and no query that surfaces them. Every forgotten suppression makes the sidebar a slightly less truthful picture of the fleet, and the sidebar's truthfulness is the entire asset this feature exists to protect.

Two cheap mitigations, either of which closes it:

- **Make `flag.list` an attention list.** Return active flags *and* suppressed surfaces (with `suppressed_by`, `suppressed_at`, and the surface refs). Same handler, same commit boundary, one more array. The operator and any agent then have exactly one place to ask "what have I muted?"
- **Record the suppressing surface.** `suppress(by:)` stores `suppressed_by_surface`. A later sweep (not in this ticket) can then notice orphaned suppressions whose parent is gone.

I would push hard for the first. It costs almost nothing and it is the only counterweight to a deliberately invisible state.

### 6. The headline use case requires thirty CLI calls

"Orchestrator with subagents" is named as *the* shape suppression serves, in the feature spec, in the mark vocabulary doc, and in the staged skill text. The primitive as specified is per-surface, one call each, with no batch form and no inheritance. An orchestrator launching thirty workers issues thirty `--suppressed` flags (fine, it is a launch flag) but an orchestrator suppressing an *existing* fleet issues thirty `c11 suppress` calls.

Two options, both small:

- **Batch refs:** `c11 suppress --surface a --surface b --surface c`, and the same for unsuppress. Trivially compatible with the "explicit non-empty surface ref required" rule (C11-165 no-focused-fallback policy is preserved: there is still no implicit target).
- **Launch inheritance:** when `launch-agent` is invoked *from* a suppressed surface and the request is agent-originated, default the child to suppressed. This is the orchestrator pattern expressed as one rule instead of thirty calls, and it is arguably what the operator means when they suppress an orchestrator's whole subtree.

Inheritance is the more interesting one and also the more opinionated. At minimum, decide it explicitly rather than by omission, because retrofitting an inheritance default after agents have written scripts against the non-inheriting behavior is a behavior break.

### 7. The latency gate measures the wrong delta and its fallback ladder reaches outside the ticket

The plan's hard pass criterion is "feature-on p95 delta versus the **static** baseline is <= 1 ms," across five configurations including "full default base motion" and "dip-only candidate."

But base motion (the stepped working fill and the waiting core dip) shipped in C11-183 at `29102376f` and is on by default. Measuring C11-184 against a static baseline charges this ticket for C11-183's cost. Worse, the pre-registered fallback ladder's first two rungs are "disable stepped fill by default" and "ship base marks static," which are reversals of a shipped, separately-decided default. That is C11-183 rework wearing a C11-184 mitigation label, and it will surface at the worst possible moment (post-implementation, pre-merge, with a tagged build and a measurement artifact arguing for it).

Separate the two questions explicitly:

- **C11-184's gate:** HEAD-with-flags versus HEAD-without-flags, *both with base motion at its shipped default*, with a realistic flag population (the design target is at most one in ten flagged, so five flagged of twenty is already a pessimistic case, not a typical one). Pass criterion applies to that delta. Its only fallback rung is "flags ship static violet," which is entirely inside this ticket.
- **C11-183's regression check:** static versus shipped-default, run once, reported as an observation. If it fails, that is a C11-183 follow-up ticket with its own decision, not a C11-184 rung.

This also cuts the measurement matrix roughly in half, which matters because the twenty-agent harness is the single largest piece of non-code work in the plan.

### 8. A mission-scoped flag means a permanent banner over live terminal pixels, and the only way to hide it destroys the flag

This is the one real design collision I found, and it sits at the intersection of three documents that each make a locally correct choice.

The feature spec establishes that a flag can scope to **a whole mission**: "the operator may flag at dispatch (a critical mission they intend to watch) ... violet for its lifetime." `launch-agent --flag "<reason>"` is a Phase 2 deliverable.

The banner mounts at the top edge of the surface, floating over terminal pixels, and updates only on attention transitions. Its dismiss control calls `lower(by: .operator)`.

Therefore: an operator who flags a mission at dispatch gets a banner permanently obscuring the top of that surface's terminal output for the entire mission, and the only available way to get rid of it is to lower the flag, which discards the mission-scope intent the flag was expressing.

The banner design is sound for the agent-raised, moment-scoped case (raise, operator arrives, reads, dismisses). It is actively hostile to the operator-raised, mission-scoped case. Options, in rough order of preference:

- **Collapse-without-lower.** The banner has two controls: a collapse chevron (banner shrinks to a small violet glyph in the corner, flag stays up, state persists per-surface) and the X (lowers). Modest additional work, resolves the collision cleanly, and the collapsed state is a useful affordance for long agent-raised flags too.
- **Auto-collapse after first view.** Banner shows full on raise and on first focus of the surface, then collapses to the glyph. No new control, less operator agency.
- **Launch-time flags render collapsed by default.** Simplest, but it means two flag classes behave differently, which contradicts the "flags arrive from either side and are one tier" framing.

Whichever is chosen, it needs to be decided in the plan rather than discovered in Phase 5, because it affects the banner's state model (per-surface collapsed state, is it persisted?), its localization strings, and its accessibility contract.

### 9. The skill text asserts visual behavior that the Phase 4 gate can invalidate

`docs/c11-attention-model-skill-section.md` says "your marks render violet across the workspace; if you are also stopped, the mark **strobes**." Phase 6 instructs copying that section "exactly," adjusting only if a *command contract* changed. But the Phase 4 latency ladder's flag rung is "ship flags static violet," which falsifies the strobe clause without changing any command.

One line in Phase 6: reconcile the staged skill text against the Phase 4 motion outcome, and update `docs/c11-attention-model-skill-section.md` in the same commit if the fallback rung was taken. Also worth noting that six locale translations land after this, so the ordering already protects you if the reconciliation is remembered.

### 10. Name the banner and the Bonsplit seam for their second consumer

Two places where a generic name costs nothing today and saves a fork later:

- `SurfaceFlagBanner` is really the first instance of a **surface overlay banner**: a top-edge, non-layout-participating, portal-owned host with a specified z-order. The obvious next consumers are mailbox message previews, CI/build status, resume-session prompts, and degraded-connection warnings. Naming it `SurfaceOverlayBanner` with a flag *content* variant, and writing the z-order matrix as a property of the host rather than of flags, means the second consumer is a content type instead of a second overlay competing for the same z-band.
- The Bonsplit presentation seam is already correctly scoped as generic host-injected color/motion (good call, and correctly identified as an upstream candidate). Push it one step further: let the presentation value carry an **opaque host-defined token** alongside the color and motion channel, so future c11 semantics require zero Bonsplit changes and zero submodule round-trips. Every avoided submodule bump is a saved push-before-pointer dance.

---

## Mutations and Wild Ideas

**Overwatch as flag triage, not flag observer.** The plan's cross-workspace story is "events are the Overwatch integration," which is correct but passive. The active version: a standing Overwatch agent tails `flag.raised`, reads the reason, and either answers it directly via mailbox (it often can: half of real blockers are "which of these two" questions an agent with fleet context can settle) or escalates to the operator with the other flags batched. That converts flags from *operator attention* to *the cheapest competent attention*, which is the actual scaling answer past thirty agents. This mutation is what justifies suggestions 1, 2, and 4: without a reply channel, resolution attribution, and enriched payloads, a triage agent can observe but not act.

**Deferred flags, or: batching attention instead of interrupting it.** `raise-flag --not-before <when>` or `--batch`. An agent that needs a human decision but not urgently queues it for the next sweep instead of firing a system notification. This is a different product philosophy (attention batching rather than attention interruption) and it is probably the correct one at fleet scale, where the interrupt cost dominates. Explicitly not v1. But note that the data model already supports it: a flag with a raise epoch and a queue is one timestamp field away from a scheduled queue.

**The signal-eligibility predicate as a general attention budget.** Once `signalEligible(notification, policy) -> Bool` exists as a pure function taking a policy object rather than reading suppression inline, do-not-disturb becomes one boolean on the policy, quiet hours become two timestamps, and "only signal me for orchestrators" becomes a role filter. For someone running thirty agents overnight, a fleet-wide DND is plausibly a more valuable feature than per-surface suppression, and this ticket accidentally builds 90% of it. **Concrete ask: give the eligibility builder a policy-struct parameter even if the struct has exactly one field today.**

**Invert the default.** If the design target is that nine in ten agents never flag, and the headline shape is an orchestrator with a suppressed subtree, then arguably silence should be the default for agent-launched surfaces and signal should be opt-in. The plan builds all the machinery for that world and ships the opposite default. I am not recommending the inversion, but the question is worth one round of thought, because the answer determines whether launch inheritance (suggestion 6) is a convenience or the actual intended model.

**Flag-to-Lattice bridge.** A flagged delegator is structurally a blocked ticket. `flag.raised` on a surface whose `worktree` metadata maps to a Lattice task becomes a comment or a status transition on that task, and `flag.lowered { resolution }` closes it. This unifies the c11 attention model with the lattice-orchestrator workflow, which is the dominant use of c11 in this shop. It requires exactly two things from this ticket: enriched raise payloads, and resolution attribution on lower. Both are already recommended above for independent reasons, which is a good sign.

**Opacity is still free.** Both docs note this explicitly. The most interesting unspent use is not another state: it is **age**. The plan correctly rejects age-based visual escalation for v1 (flags do not decay). But when the operator has fifteen flags up and Overwatch is triaging, "which of these has been starving longest" is exactly the question the queue answers and the UI does not. Opacity, or nothing at all in the mark and a simple relative-age string in the Flagged Agents row, is the cheapest possible version. Worth naming as the v1.1 that the queue epoch already enables.

---

## What It Unlocks

Once C11-184 ships, these become available and mostly do not exist today:

1. **An attention queue readable without the app running.** `flag.list` plus the events file (which `c11 events tail` reads directly, no running app required) means external schedulers, cron escalation, and other machines on the tailnet can reason about which agent is starving.
2. **Attribution vocabulary in the metadata layer.** `by: operator | agent` is the first time c11 records *who* made a metadata assertion. Extending that to `status`, `task`, and `progress` (who set this, the agent or the operator?) is now one enum away, and it is the missing half of the existing source-precedence chain (`explicit > declare > osc > heuristic` tells you the tier, not the author).
3. **A reusable surface overlay band** with a settled z-order contract (see suggestion 10).
4. **A generic Bonsplit host-presentation channel**, which is both an upstream contribution and the end of per-semantic Bonsplit forks.
5. **A signal-eligibility abstraction** that is the foundation of every future notification policy c11 will want.
6. **A closed operator/agent loop with recorded outcomes**, which is the prerequisite for any future measurement of whether the fleet's attention demands are calibrated. You could, a month after shipping, answer: how many flags per agent-hour, what fraction get answered versus deferred, which roles over-flag. None of that is knowable today.

---

## Sequencing and Compounding

**The one structural change I would push hardest for: split at Phase 3/4.**

- **PR 1 (Phases 0 to 3, plus the events and skill contract):** canonical metadata, the attention service and commit boundary, socket methods, CLI commands, launch flags, raw/signal index split, waiting edges, direct notification delivery, oldest-first navigation, all four events, `flag.list`. Zero rendering. Zero Bonsplit. Zero submodule pointer commit. Zero latency gate. This is a complete product: agents can flag, the operator's Option-V prioritizes correctly, Overwatch and cron can consume, and the Lattice bridge becomes possible.
- **PR 2 (Phases 4 to 5):** both renderers, the motion policy split, the Flagged Agents row, the banner, the fleet-latency gate, the tagged visual evidence.

Why this ordering compounds: PR 1's output (a live event stream with real flags in it) is PR 2's *input* for validation. You will have days of real flag data before you tune the violet, which is exactly the operator's stated method ("dialled in the tagged build"). And a latency failure in PR 2 cannot strand the primitive.

The one coupling is the skill text, which asserts visual behavior. Land the skill's command half with PR 1 and its visual half with PR 2, or land the whole section with PR 2 and accept that agents cannot discover the commands for a few days. Given the skill-sync hard rule, the two-part landing is more work; the simplest resolution is to soften two clauses in the staged skill text so the whole section can land with PR 1.

**Within PR 1, invert one sub-ordering.** The plan puts navigation (Option-V, the jump selector) in Phase 3 alongside the signal layer. Consider landing `flag.list` and the four events *before* the navigation rework. The external consumers are what make the primitive worth having and they need zero UI, zero AppDelegate changes, and zero jump-selector risk. Getting them into an operator's hands a day earlier is worth more than Option-V prioritization, which the operator can approximate with `flag.list` in the meantime.

**Where to spend more than the plan does:** the event payload shapes. Everything else in this ticket is internal and revisable at will. The event schema is v1, is documented in `skills/c11/references/events.md`, has a JSON schema file, and will have external consumers within a week. An extra hour on `flag.raised` and `flag.lowered` payloads is the highest-return hour in the ticket.

**Where to spend less:** the fleet-latency protocol. Five configurations, p50 and p95 each, twenty-plus agents, subscriber-count inspection, and a three-rung ladder is a substantial harness for a motion feature that by design appears on at most one surface in ten. With the baseline correction from suggestion 7, the matrix collapses to two configurations (flags-off, flags-on-at-pessimistic-population) plus one subscriber-count assertion, and the ladder to a single rung.

**Defer as a runtime default, not a compile-time branch.** The operator-held Phase 3 decision (does a flag raise on a suppressed surface deliver a system notification?) is correctly isolated to one policy branch. Make that branch read a `UserDefaults` key with a shipped default of "no," rather than a compile-time constant. The branch already exists; making it a default costs one read and lets the operator resolve the question empirically over a week of overnight sweeps instead of in advance. This is exactly the kind of question that is easier to answer with the feature in hand.

---

## The Flywheel

**The loop the feature depends on, and which the plan does not quite close.**

The stated regulation mechanism for flag scarcity is social: "an agent that interrupts for nothing gets told so." No enforcement, no rate limit, correctly. But that loop only turns if the agent *observes the outcome of its flag*, and right now the entire observable outcome is `by: operator | agent`. An agent that flags well and an agent that flags badly receive the identical signal.

```
flags are rare  ->  flags are trusted  ->  operator answers fast
      ^                                            |
      |                                            v
agents calibrate  <-  agents observe outcomes  <-  outcome is recorded
                             ^
                             |
                    (this arrow is one bit wide)
```

Widening that arrow is suggestion 2 (`resolution`) and suggestion 1 (a reply channel). With both, an agent learns not just that it was seen but whether the flag *produced a decision*, and the skill's re-raise guidance becomes a real decision procedure rather than an exhortation. This is the flywheel engineering move available in this ticket, and it is small.

**The second loop, which needs suggestion 4.**

```
flags emit rich events  ->  Overwatch triages  ->  fewer flags reach the operator
        ^                                                       |
        |                                                       v
agents flag more freely  <-  operator tolerance for flags rises  <-
```

This is the one that actually scales past thirty agents, and it is entirely gated on the raise payload carrying enough context to route on.

**The anti-flywheel to watch.**

Suppression is invisible, permanent, per-surface, and has no audit surface. Each forgotten suppression makes the sidebar a slightly less complete picture of the fleet. That degradation is silent by construction and compounds monotonically. Nothing in the plan reverses it. This is the strongest independent argument for suggestion 5 (make `flag.list` an attention list), and I would treat it as a v1 requirement rather than a nicety, because it is the only brake on the one mechanism in this feature that can quietly make the sidebar lie.

---

## Concrete Suggestions

Ordered by value per unit of effort.

1. **Enrich the two flag event payloads before writing any handler code.**
   `flag.raised { reason, raised_at, revision, task?, role?, title? }` and
   `flag.lowered { by, resolution, note? }`.
   Cost: about an hour, plus the schema file and `references/events.md`. Value: unblocks Overwatch triage, cron escalation, the Lattice bridge, and the agent-calibration flywheel, and avoids a schema v1 break. Do this first.

2. **Make `flag.list` an attention list that includes suppressed surfaces.** Same handler, same commit boundary, one additional array carrying refs, `suppressed_at`, and `suppressed_by`. This is the only counterweight to a deliberately invisible state, and without it the feature's most valuable mode is also its least auditable.

3. **Split the ticket at Phase 3/4 into two PRs.** Model, primitives, signal layer, navigation, events, skill in PR 1; renderers, motion, row, banner, latency gate in PR 2. Decouples a hard visual ship blocker from a primitive with independent value, and gives PR 2 real flag data to tune against.

4. **Correct the latency baseline and shrink the matrix.** Measure C11-184's delta against HEAD-with-base-motion, not against static. Restrict the fallback ladder to the one rung that lives inside this ticket ("flags ship static violet"). If the base-motion-versus-static observation is worth having, record it as an observation feeding a C11-183 follow-up, not as a C11-184 rung.

5. **Resolve the mission-flag banner collision explicitly, in the plan.** Add a collapse-without-lower control to the banner. Specify whether collapsed state is per-surface and whether it persists across restore. This affects the banner state model, two localized strings, and the accessibility contract, so it is much cheaper decided now than discovered in Phase 5.

6. **Give the signal-eligibility builder a policy-struct parameter**, even if the struct has one field today. `eligibility(for: notification, policy: AttentionSignalPolicy)` rather than an inline suppression read. This is the seam that later carries do-not-disturb, quiet hours, and role filters at near-zero marginal cost.

7. **Decide suppression batching and launch inheritance explicitly.** At minimum accept repeated `--surface` refs on suppress/unsuppress. Separately, decide whether an agent-originated `launch-agent` from a suppressed surface defaults the child to suppressed, and record the decision either way, because retrofitting it is a behavior break.

8. **Name the banner host and the Bonsplit token generically.** `SurfaceOverlayBanner` with a flag content variant; a Bonsplit presentation value carrying an opaque host token alongside color and motion. Zero cost today, one avoided fork and one avoided submodule round-trip later.

9. **Ship the operator-held Phase 3 decision as a `UserDefaults` key** with the spec-faithful default of "no direct delivery on suppressed surfaces," rather than as a compile-time branch. The branch already exists; making it a default turns a blocking decision into an empirical one.

10. **Add one reconciliation step to Phase 6:** if the Phase 4 latency ladder took the static-violet rung, update the strobe clause in both `docs/c11-attention-model-skill-section.md` and `skills/c11/SKILL.md` before the translator stage runs.

11. **Reserve a paragraph in the plan's non-goals for the v2 direction**, so the shape is on record: flag replies over the existing mailbox transport, deferred/batched flags, an attention list surfacing suppression, and Overwatch triage. Non-goals that name the intended successor are worth more than non-goals that only say no.

---

## Questions for the Plan Author

1. **Is the flag a notification or a question?** The reason string, the required-not-optional rule, and the motivating example ("Need a call on schema migration vs dual-write") all say question. The reply vocabulary (one X) says notification. Which is it in v1, and if it is a notification in v1 and a question in v2, are you willing to spend the two optional payload fields now to keep v2 non-breaking?

2. **Will you split at Phase 3/4?** Specifically: is there a reason the primitive and event layer must ship in the same PR as the renderers, other than the skill text asserting visual behavior? If the skill text is the only coupling, would you soften two clauses to decouple them?

3. **What is the audit story for suppression?** Given that suppression is deliberately invisible with no badge, no dim, and no distinguishable mark, how does the operator answer "what have I muted?" a week later? If the answer is `get-metadata` per surface, is that acceptable at thirty surfaces?

4. **Does `launch-agent` from a suppressed agent surface inherit suppression?** The orchestrator/subagent shape is named as the primary use case in three documents. Inheritance makes it one rule; non-inheritance makes it N calls. Either is defensible, but the decision should not be made by omission.

5. **What happens to the banner on an operator-set mission-scoped flag?** A permanently-visible banner over live TUI output for the mission's lifetime, dismissable only by destroying the flag, is the current specification. Is that intended, and if not, is a collapse-without-lower control in scope for v1?

6. **Should the latency gate's fallback ladder be allowed to change a C11-183 default?** Two of the three rungs reverse a shipped, separately-decided motion default. Is that in C11-184's remit, or should the ladder be restricted to the flag rung?

7. **What is the intended relationship between flags and the existing mailbox system?** They are two agent-to-human/agent channels that currently do not know about each other. Is flag-plus-mailbox-reply the roadmap, or are they deliberately separate concerns?

8. **How will you know, three months in, whether the attention model is calibrated?** Flags per agent-hour, answered-versus-deferred ratio, mean time-to-lower, flag rate by role: all of that is derivable from the event stream *if* the payloads carry enough. Is measuring the feature's own calibration a goal, and if so does the current payload support it?

9. **Is silence the right default at fleet scale?** The feature's target is that nine in ten agents never flag and the headline shape is a suppressed subtree. If that is the world, should agent-launched surfaces default to suppressed and opt into signalling, rather than the reverse? Not a v1 change, but the answer determines whether inheritance (question 4) is a convenience or the actual model.

10. **What is the second consumer of the surface overlay band?** If you can name one (mailbox previews, CI status, resume prompts), that is sufficient justification to build the host generically in Phase 5 rather than refactoring it out later.

---

## Where the Plan Is Already Strong

Worth stating plainly, because most of the above is additive rather than corrective:

- The serialized attention-commit service with an explicit commit-before-response ordering, and the closure of every generic-metadata bypass (set, clear, replace, restore, launch, transfer, close, prune) with adversarial coverage, is exactly right and is the kind of thing usually discovered in review rather than specified in the plan.
- The active-to-active revision semantics (preserve epoch, no second queue entry, no age reset) is precise, and it is the sort of detail that produces a real bug if left implicit. The only gap is that it is not observable on the wire (suggestion 1).
- Keeping Bonsplit generic and naming the upstream candidacy without opening the upstream PR during the task is the correct call under the repo's bidirectional-upstream policy.
- Isolating the operator-held decision to a single call-site branch with an explicit statement that nothing else may depend on it is a model for how to defer a policy question without stalling implementation.
- The submodule detached-HEAD prevention gate, the single tagged launch with recorded bundle/PID/socket, and the CI-is-sole-test-executor constraint all reflect real prior pain in this repo and are correctly encoded.
- Splitting base-motion permission from explicit-motion permission, rather than trying to express "Static marks disables base but not flag motion" through the existing single boolean, is the right architectural call and correctly identified as a change to the *generic* host policy rather than a c11-specific hack.
