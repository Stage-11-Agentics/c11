# Mailbox — Evolutionary Review (MODEL=Claude, LENS=evolutionary)

*Read against `Sources/Mailbox/*.swift`, `CLI/c11.swift` mailbox section, `Sources/Workspace.swift` / `AppDelegate.swift` wiring, `skills/c11/SKILL.md`, `docs/c11-mailbox-guide.md`, `docs/c11-messaging-primitive-design.md`, the merged #251 diff. This is the headline lens: how should this thing mutate, or is it enough?*

---

## 1. What is this, really?

Strip the framing and look at the mechanics: a **filesystem-backed, name-addressed, per-workspace-dispatched, locally-resolved message bus for a swarm of agents on one host.** Each of those adjectives is load-bearing and each one is a fork in the road.

But the *deep structure* — the thing the design keeps almost-saying and never quite names — is this:

**The mailbox is an actor mailbox in the Hewitt/Erlang sense, and the c11 surface is the actor.** Every surface has a name (an address), a single inbox (an unbounded ordered-ish queue), and a delivery discipline it *declares for itself* (`mailbox.delivery`, receiver-decides). Senders cannot reach into a recipient's execution; they can only drop a message in its mailbox and optionally hint (`urgent`). That is the actor model, almost line for line. The `<c11-msg>` block is the message; `reply_to`/`in_reply_to` is the actor's correlation primitive; "coordination emerges from the topic graph, no orchestrator" (design doc §11) is the actor-model thesis stated out loud.

This matters because the most powerful framing is not "message queue" (implies a broker, ordering, backpressure you don't have) and not "IPC bus" (implies symmetric peers; these aren't symmetric — they're addressable actors with private state). The most powerful framing is: **c11 is becoming a single-host actor runtime where the actors happen to be LLM agents in PTYs, and the mailbox is its message-passing layer.** Once you hold that frame, the roadmap writes itself, because the actor model already tells you what's missing: supervision, monitoring (links/monitors), naming/registry (you have this, it's `title`), and — the one genuinely hard part for LLM actors — *that the "process" reading the mailbox is a stochastic text model, not deterministic code.*

That last clause is where this stops being a known quantity and becomes interesting. In Erlang the receiver is a `receive` loop that reliably consumes its mailbox. Here the receiver is Claude/Codex/Kimi, which may: never read the inbox, read the framed block and ignore it, hallucinate a reply, be mid-tool-call for ten minutes, or have compacted the message out of its context window by the time it acts. **The mailbox delivers; it cannot make the actor process.** Every mutation decision downstream is really a decision about how much the *substrate* should compensate for the *unreliability of the actor*, versus pushing that onto the skill/protocol layer. That is the axis the operator is really asking about.

The single best one-line name: **a name-addressed actor mailbox for a local LLM agent swarm, with the filesystem as the durable queue and the PTY as a best-effort doorbell.** Hold "doorbell, not delivery" in your head — it's the most clarifying distinction in the whole design.

---

## 2. How will it actually be used?

Project the real operator: 8–30 agents, lattice-orchestrator (one orchestrator + N delegators in worktrees) and overwatch (one meta-agent above the orchestrators). Map the message patterns that *will actually fire* against what the design serves:

**Patterns that emerge, ranked by how often they'll fire:**

1. **Handoff / fire-and-forget notification** ("done, PR open at X", "I'm blocked on Y, need a decision"). This is 80% of real traffic and the design serves it *perfectly*. Name-addressed `to`, durable inbox, framed block into the PTY of a stdin-delivery agent. This is the load-bearing use case and it's solid today.

2. **Request / reply** (orchestrator asks a delegator "status?", delegator replies). Served via `reply_to`/`in_reply_to`. Works, but with a sharp edge: **there is no correlation timeout and no "the actor I asked is dead/stuck" signal.** The orchestrator sends a request and then... waits, with no primitive telling it whether the reply is coming. In an 8-agent fleet a human notices a hung delegator; in a 30-agent overnight run nobody notices until morning. This is the first wall operators hit.

3. **Broadcast / fan-out** (orchestrator: "stop all work, main is broken" to every delegator; overwatch: "report status" to every orchestrator). This is the **single biggest gap** and operators will hit it within the first real session. Today the answer is "loop over `--to` for each name" — which means the *sender* maintains the recipient list, the sender's loop is the fan-out, and there's no group address. For a swarm this is exactly backwards: the whole point of 30 agents is you don't want to enumerate them. Topic fan-out (Stage 3) partially fixes this, but topics are pull-shaped (subscribers self-declare); what the operator wants is often *push to a role* ("all delegators") which is closer to a **group/role address** than a topic.

4. **Supervision / heartbeat** ("are you alive?", "I haven't heard from delegator-3 in 20 min"). **Not served at all, and it's the one that bites hardest in the 30-agent overnight case.** When you can hold 8 agents in one field of view, you supervise with your eyes. At 30, across workspaces, half off-screen, the operator *is asleep* — supervision has to be a primitive or it doesn't exist. The actor framing screams for Erlang-style monitors here: "tell me when surface X dies or goes quiet."

5. **Work-stealing / queue** (a pool of worker agents pull from a shared backlog). The design explicitly is *not* this — there's no shared consumable queue, inboxes are per-recipient and push-delivered. Operators *might* fake it (one "dispatcher agent" hands work out via `to`), but the substrate doesn't help. I'd argue this is *correctly* out of scope; Lattice tickets are the work queue, the mailbox is the nervous system. Don't build work-stealing into the mailbox.

**Where today's design fights real usage:**

- **Mutable, non-unique `title` as the address.** This is the deepest structural tension in the whole feature (see §4, leverage point #1). Operators and agents rename surfaces constantly. The address *is* the display name. An agent that renames its tab from "delegator-3" to "✳ Fixing the socket bug" has just silently changed its mailbox address and dropped off the bus. Every reply addressed to "delegator-3" now rejects-unresolved. In an 8-agent session you'd catch it; in a 30-agent run it's a silent partition.

- **At-least-once-but-only-steady-state + no `_processing/` recovery** in exactly the workflow (overnight, 30 agents, reloads happen) where crash-window durability matters most. The Stage-2 caveat is honestly documented, but the documentation doesn't make the lost message reappear at 3am.

- **No delivery confirmation the *sender* can see.** `_dispatch.log` records `handler ok`, but "ok" means "bytes were written to the PTY," not "the agent read it" — and certainly not "the agent acted." The sender gets no receipt. For fire-and-forget that's fine. For "stop all work" it's a latent disaster: you broadcast the stop, three agents were mid-tool-call and never parsed it, and you have no idea which three.

**First wall, concretely:** the operator runs an overnight orchestration, a delegator silently renames itself or dies, and the morning state is "orchestrator sent it three messages, all rejected-unresolved, orchestrator kept waiting, nothing flagged it." The mailbox did everything right per its contract and the swarm still deadlocked, because the contract has no liveness story.

---

## 3. Is it enough as-is?

**Honest call: it is enough to ship and dogfood, and it is NOT enough to be the coordination substrate for a 30-agent unattended run. Those are different bars and the operator is asking about the second one.**

For the *first* bar — "let agents in separate surfaces coordinate, c11 imposes no protocol" — the Stage-2 + cross-workspace feature is genuinely sufficient and most further envelope-schema work would be gold-plating. The primitive is clean: filesystem-as-contract, name addressing, framed PTY block, dispatch log, parity test. The cross-workspace + non-silent-rejection change (#251) was the *right* next increment and closed the worst silent-failure mode. I would not add `body_ref` read-through, TOON output, content-type negotiation, or richer envelope fields right now — that's all polishing a primitive that's already expressive enough. The envelope is *done*; resist the urge to keep enriching it.

But there is **one specific missing capability without which it stays a toy for the headline mission**, and it's not topics: **liveness/supervision.** The mailbox can deliver a message to an actor that will never process it, and *nothing in the system can tell the sender that.* For an operator watching 8 agents, their eyes are the supervisor. For 30 agents across workspaces overnight, there is no supervisor, and a coordination bus without a liveness signal is a bus where deadlocks are invisible. That's the line between "interesting structure I dogfood" and "infrastructure I trust with an unattended run."

So: **enough as a primitive, not enough as infrastructure.** The gap is exactly one concept (liveness), not ten. That's good news — it means the thing is 90% done, not 50%.

---

## 4. Mutation vectors — ranked by leverage

Leverage = (unlock) / (cost × risk). Ranked. The top two are the leverage points.

### ⭐ LEVERAGE POINT #1 — Stable address alongside the mutable title

**What:** give every surface a stable mailbox address that does *not* change when the title changes. Two clean options: (a) make the surface's own ULID/`surfaceId` directly addressable (`--to surface:01K…`), or (b) add an explicit `mailbox.address` (or `mailbox.role`) metadata key that, when set, is the address — falling back to `title` when unset. Resolution checks address-key first, then title.

**Unlocks:** the bus stops silently partitioning every time an agent renames its tab (which they do constantly — the global CLAUDE.md *mandates* tab-renaming as the first action). Reply chains survive renames. Roles ("delegator", "orchestrator") become stable handles independent of display vanity. This is the foundation every other reliability mutation sits on — supervision, group addressing, and receipts all assume the address you sent to is the address that's still there.

**Cost:** small. The resolver already enumerates surfaces and reads metadata; add one key lookup with title-fallback in `MailboxGlobalResolver.resolve` and `surfacesWithMailboxMetadata`. CLI gains a `surface:<ulid>` qualifier form (the codebase already has `workspace:*` qualifier parsing to mirror). No schema change — `to` is already an opaque string.

**Risk:** low. Backward-compatible (title remains the default address). The only subtlety is precedence and collision rules, which the existing local-first/ambiguous machinery already models.

**Why #1:** it's the cheapest change that removes the most insidious *silent* failure mode, and it's a prerequisite for trusting the bus over a long run. Mutable identity is the original sin of the current design; fix it before building anything on top.

### ⭐ LEVERAGE POINT #2 — Liveness as a first-class signal (presence + monitor)

**What:** two sub-pieces, smallest first.
  - **(a) Presence:** the dispatcher (or a thin sweep) already enumerates live surfaces. Expose it: `c11 mailbox who` / `c11 mailbox resolve --to <name>` returning live/dead + which workspace. The CLI *already calls* `mailbox.resolve` internally on every send — surface it as a queryable so an agent can check "is my recipient alive?" *before* it blocks waiting for a reply.
  - **(b) Monitor / dead-letter-on-close:** when a surface closes, any sender with an outstanding `in_reply_to` correlation gets a synthetic `<c11-msg>` "recipient closed" (Erlang's `'DOWN'` message), or at minimum the `_dispatch.log` gets a `recipient_closed` event the overwatch agent can tail. Even cheaper: a `c11 mailbox send --expect-reply --timeout 300` that, on no matching `in_reply_to` within the window, emits a timeout event the sender can poll.

**Unlocks:** this is the capability that makes §3's "toy → infrastructure" jump. The orchestrator can ask "is delegator-3 still alive?" and the overwatch agent can tail one stream and see "delegator-3 went quiet 20 min ago, orchestrator has an unanswered request to it." Deadlocks become *visible*, which for an unattended swarm is the whole game.

**Cost:** medium. Presence (a) is nearly free — it's exposing data the resolver already has. Monitor (b) is more — the dispatcher would need to track outstanding correlations or hook surface-close. Start with (a) and the `recipient_closed` log event; defer the synthetic `'DOWN'` message.

**Risk:** medium. The honest risk is that the actor here is stochastic — "alive" (PTY exists) is not "responsive" (will process its inbox). Presence answers the first, not the second. Don't oversell it. But "the PTY is gone" is a real, common, currently-invisible failure, and catching just that is worth a lot.

### #3 — Topic / role pub-sub fan-out (Stage 3, already planned)

**What:** the planned `mailbox.subscribe` glob fan-out, *plus* I'd fold in **group/role addressing** (`--to @delegators` resolves to every surface with `mailbox.role=delegator`). The design treats topics as the fan-out story, but in practice the operator wants *push-to-role* ("all delegators stop") more than *pull-by-topic* ("I subscribe to build.*"). Both ride the same dispatch-time-resolution machinery.

**Unlocks:** broadcast without the sender enumerating recipients — the §2 gap #3. Essential for overwatch ("report status" to all) and orchestrator ("abort" to all delegators).

**Cost:** medium, mostly already scoped. The resolver fans out a `topic`/role against all surfaces' subscribe/role metadata. Group addressing is *cheaper* than glob topics (exact role match, no glob engine) and arguably should ship first as the 80% case.

**Risk:** medium. Fan-out amplifies the PTY-injection blast radius — a malformed broadcast hits N agents at once. The receiver-declared delivery discipline contains this (only stdin-opted surfaces get PTY writes), but test it under fan-out load.

### #4 — `_processing/` crash-recovery sweep (Stage 3, planned)

**What:** the documented TODO — on start, sweep surviving `_processing/*.msg` back to `_outbox/` (receivers dedupe by id, so it's safe by construction).

**Unlocks:** closes the crash-window hole in at-least-once. Matters specifically for the overnight/reload case.

**Cost:** small — it's ~20 lines and the design already specifies it. The reason it's #4 not higher: in practice the window is tiny (move-to-processing → inbox-copy is microseconds), and the inbox copy is what carries durability. It's a real hole but a narrow one. Ship it, but it's not the thing standing between toy and infrastructure.

**Risk:** very low. Dedupe-by-id makes redelivery safe.

### #5 — Sender-visible receipt / ack primitive

**What:** an optional `mailbox.recv`-emits-`delivered` event, or an agent-level convention where reading the inbox writes a receipt back. The design *deliberately* punted acks to "developer-land on top" — and that was the right v1 call. But the *substrate* could cheaply record "recipient drained this id from inbox," distinct from "PTY write ok."

**Unlocks:** the difference between "I wrote bytes to a PTY" and "the agent consumed the message." Closes §2's "no receipt" gap for the broadcast-stop case.

**Cost:** low-medium. `recv --drain` already unlinks; have it append a `delivered` log event. Doesn't force a protocol, just makes consumption observable.

**Risk:** low, but beware scope creep into a full ack/retry protocol. Keep it to *observability of consumption*, not guaranteed delivery semantics. The actor read its mailbox ≠ the actor acted; don't let "delivered" masquerade as "acked."

### #6 — Cross-host / tailnet (Atlas + Hyperion)

**What:** the operator runs two always-on-ish machines on a tailnet. Today the mailbox is single-host-single-process. A cross-host bridge (a `webhook`/sync handler, or a tailnet-aware resolver) would let an agent on Hyperion message an agent on Atlas.

**Unlocks:** genuinely new capability — the swarm spans machines. The persistent agentic host (Atlas, Hermes) becoming addressable from the laptop is real.

**Cost:** high, and it reopens the security model the design explicitly deferred (`from` is sender-attested, fine for same-user-same-host; *not* fine across a network boundary). This is where the deferred auth pass becomes mandatory.

**Risk:** high. Don't do this until §4 #1 (stable address) and a real identity story exist. It's the most exciting mutation and the one most likely to go wrong if rushed. **Name it, don't build it yet.**

### #7 — Observability surface (mailbox dashboard / overwatch view)

**What:** a c11 markdown or browser surface rendering live `_dispatch.log` across workspaces — who's talking to whom, unanswered requests, rejected sends. The overwatch skill is the natural consumer.

**Unlocks:** the operator *sees* the swarm's nervous system. Pairs with #2 (liveness) to make the 30-agent case legible.

**Cost:** medium (it's a UI on top of existing logs).

**Risk:** low. Pure addition. Good fast-follow once #2 exists, because a liveness view with nothing to show is just a log tailer.

---

## 5. Wildest mutations (name them, mostly don't build them yet)

- **The mailbox as the kernel of a local multi-agent OS.** Follow the actor framing all the way: surfaces are processes, the mailbox is IPC, Lattice tickets are the scheduler's run-queue, c11 is the kernel. If c11 is "a macOS command center for the operator:agent pair," the mailbox is the syscall layer for agent-to-agent. This is the *true* north star and most of §4 is incremental steps toward it. Worth holding as the organizing metaphor even if no single PR is "build the OS."

- **The framed `<c11-msg>` block as a provider-neutral agent-to-agent wire protocol that outlives c11.** This is genuinely the highest-leverage *idea* in the whole feature, and it's almost free. The block is LLM-native (every frontier model parses `<tag attr>…</tag>` instantly), transport-agnostic (it's just text in a stream), and already has injection-defense baked in. There is no reason it should be c11-specific. **Spec'ing `<agent-msg>` as a standalone, documented wire format** — the way Anthropic ships MCP — would let it ride Slack, tmux, SSH, a webhook, anything with a text channel. c11 becomes the *reference implementation* of a format, not the owner of a feature. Given the cmux↔c11 open-source posture and the Stage 11 thesis (orchestration tech), this is the mutation with the largest possible surface area and the smallest code cost: it's mostly a doc and a name. I'd seriously consider it.

- **Content-addressed message log as shared swarm memory.** The `_dispatch.log` is already an append-only event log. Make message bodies content-addressed (hash → `blobs/`), and the log becomes a replayable, dedupable, shared episodic memory the whole swarm can query: "what did anyone learn about the socket bug?" Speculative, possibly over-engineered, but it's the natural endpoint of "the log is the cheapest high-leverage piece."

- **Self-organizing topologies.** Once group/role addressing + presence exist, agents could form their own coordination graphs (a delegator spawns sub-workers and registers them as a role). The substrate wouldn't change; the *behavior* emerges. This is the actor-model promise — "coordination emerges from the graph" — taken to its conclusion. Don't build it; *enable* it (via #1, #2, #3) and watch what the swarm does.

- **Mailbox as the human↔swarm seam.** The operator is also an addressable actor. `c11 mailbox send --to operator` could surface in the sidebar / a notification, and the operator replies into the bus. The overwatch agent already wants to be "the one agent you talk to." Make the *human* a first-class mailbox address and the bus becomes the single coordination plane for human + swarm, not two systems bolted together.

---

## 6. What to remove or simplify

Evolution is subtraction. Candidates:

- **`watch` handler and `c11 mailbox watch` (unimplemented stub).** It throws "not implemented; see tail." Either kill the subcommand entirely or make it an alias for `tail`. A command that exists only to error is a worse experience than no command. The design's three-handler vision (`stdin`/`silent`/`watch`) is cleaner as two (`stdin`/`silent`) + `tail` for streams. **Remove the stub.**

- **`body_ref` accepted-but-not-read-through.** The dispatcher validates and stores `body_ref` but no one reads it; the recipient is told to read the file itself. This is a half-primitive: it *looks* like a feature but the substrate does nothing with it. Either finish it (read-through, with the `blobs/` allowlist enforced) or document it purely as a sender convention and stop validating it as if c11 owns it. The current middle state is a maintenance trap — it implies a guarantee c11 doesn't make.

- **`content_type`, `ttl_seconds` (dispatcher doesn't enforce), `ext`.** These are envelope fields the dispatcher accepts and ignores. They're not *wrong* — they're forward-compat hooks and `ext` is explicitly the escape hatch — but every accepted-but-ignored field is a place a future reader assumes a guarantee that isn't there (`ttl_seconds` especially reads like "c11 expires this"; it doesn't). I wouldn't remove them, but I'd **audit the validator's job**: it should validate *shape* and stop implying *behavior*. One sentence in the schema per ignored field: "advisory; c11 does not act on this." (The TTL one already says this in the design doc; make sure the schema/skill say it at the point of use.)

- **The 2s handler-timeout *and* the 500ms stdin-handler-timeout as two separate reporting bounds.** Two nested timeouts (dispatcher's 2s semaphore wait around the handler, handler's 500ms continuation race) that are both explicitly "reporting bounds, not runtime bounds" and neither of which can actually interrupt a blocked main-thread write. This is a lot of concurrency machinery (the `ContinuationGate`, the double-Task race, the semaphore) defending against a writer that "in practice returns in microseconds." It's not *wrong*, but it's the most over-built corner of the feature relative to the risk it addresses. When the genuine async-cancellable PTY write lands (the documented follow-up), collapse this to one bound. Until then, it's accepted complexity — just flag it as the thing to simplify the moment the real writer exists.

Nothing else is over-built. The core pipeline (outbox→processing→validate→resolve→copy→handlers→cleaned) is appropriately lean, and the parity test + single-validator discipline are exactly the right amount of rigor for a load-bearing public format. Don't touch those.

---

## The single most important mutation

**Make the address stable, then make liveness visible — in that order, and treat them as one move.** Everything else (topics, recovery sweep, receipts, cross-host) is a refinement of a bus that already works for the 80% handoff case. But the headline mission — coordinate a 30-agent swarm the operator *cannot watch* — has exactly one structural hole, and it has two halves that share a root: the address is the mutable display title (so the bus silently partitions when agents rename themselves, which they're *instructed* to do), and there is no signal that a recipient is alive/dead/quiet (so deadlocks are invisible). Stable addressing (§4 #1, nearly free, no schema change) removes the silent partition; presence + monitor (§4 #2, mostly exposing data the resolver already computes) removes the invisible deadlock. Ship those two and the mailbox crosses from "interesting structure I dogfood with 8 agents in view" to "infrastructure I trust to coordinate 30 agents while I sleep." Resist enriching the envelope, resist cross-host, resist work-stealing — those are the seductive mutations and they're all premature. The boring one (stable identity + liveness) is the one that earns the operator's trust, and trust is the only currency that matters for unattended orchestration. And while you're in the docs, *name the `<c11-msg>` format as a standalone wire protocol* — that's the near-free mutation with the largest possible surface area, and it costs a doc and a decision, not code.

## How the operator actually uses it in 3 months

In three months this is the nervous system of every lattice-orchestrator run, and the operator barely thinks about it — which is the goal. The dominant pattern is exactly what the design serves best: delegators fire "PR open at X / blocked on Y, need a decision" handoffs into the orchestrator's PTY, the orchestrator routes decisions back, and the framed block showing up between prompts becomes as native to the agents as a tool result. The operator's *own* interaction will be through overwatch: one agent, sitting above the fleet, tailing `_dispatch.log` across workspaces, answering "what's the state of everything?" by reading who's messaged whom — and the first feature request that lands, hard, the first time a 20-agent overnight run silently deadlocks because a delegator renamed itself or died unanswered, will be *exactly* the stable-address + liveness mutation above. They'll discover the gap the way the design predicted the silent-drop gap (which #251 just fixed): not in review, but at 7am looking at a run that did everything right per contract and still hung. The mutation that ships next is the one that makes that 7am moment a flagged alert instead of a forensic dig. Topics will get used, but less than expected — the operator will reach for *role broadcast* ("all delegators, abort") far more than *topic subscribe*, and will be mildly annoyed that the planned Stage 3 gave them the pull-shaped primitive when they wanted the push-shaped one.
