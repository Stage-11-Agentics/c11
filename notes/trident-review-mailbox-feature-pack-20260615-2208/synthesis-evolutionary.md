# Mailbox — Evolutionary Synthesis (HEADLINE LENS)

*Synthesis of the Evolutionary-lens reviews of the c11 mailbox feature pack. **This reflects 2 of 3 models** — Claude and Gemini. **Codex was absent** (usage cap), so where a tie-breaker would normally exist, there is none; the dissent in §8 is a genuine 1-vs-1 split, not a 2-vs-1 majority.*

---

## 1. Executive summary

**The single biggest opportunity is stable addressing.** Both models, independently and as their #1 vector, say the same thing: the mailbox address is currently the *mutable display title*, and the global CLAUDE.md *mandates* that agents rename their tab as their first action. So the bus silently re-partitions the instant an agent renames itself — which it is instructed to do. This is the deepest structural flaw, it is nearly free to fix (the resolver already reads metadata; add one key lookup with title-fallback, no schema change), and every other reliability mutation sits on top of it. Fix this first or build nothing on top.

**Honest "is it enough as-is?" call:** It is enough as a *primitive* to ship and dogfood with 8 agents in one field of view. It is **not** enough as *infrastructure* for the headline mission — coordinating a 30-agent unattended run the operator cannot watch. The two models name *different* second holes (Claude: liveness/supervision; Gemini: stdin PTY delivery is unsafe under concurrency), but they agree on the verdict and agree the envelope itself is done. The good news: the gap is one or two concepts, not ten. The thing is ~90% done as a primitive and the remaining 10% is exactly the part that earns operator trust for unattended runs.

**The honest one-liner:** ship stable addressing now (both models, unanimous, cheap), then resolve the §8 dissent on *whether the next wall is liveness or unsafe delivery* — because that choice is the actual fork in the road, and the two models split clean on it.

---

## 2. What this primitive really is

Both models converge hard on the **actor model**, from different doors. This convergence is the most important framing signal in the whole review.

- **Claude's framing — "a name-addressed actor mailbox; the filesystem is the durable queue, the PTY is a best-effort doorbell."** The deep structure is Hewitt/Erlang: every surface has a name (address), a single inbox (queue), and a delivery discipline it declares *for itself* (receiver-decides). `reply_to`/`in_reply_to` is the correlation primitive; "coordination emerges from the topic graph, no orchestrator" is the actor-model thesis stated out loud. **What it unlocks:** the actor model *already tells you what's missing* — supervision, monitors, naming/registry. The roadmap writes itself. The one genuinely hard part is that the "process" reading the mailbox is a stochastic text model, not deterministic code: **the mailbox delivers; it cannot make the actor process.** Hold "doorbell, not delivery" in your head.

- **Gemini's framing — "a filesystem-backed distributed actor-model runtime; everything is a file."** Same actor destination, but it weights the *filesystem-IPC* property as the source of resilience: crash the daemon and committed messages survive because they're on disk. Unix philosophy applied to swarm orchestration. **What it unlocks:** the filesystem contract is the durable, inspectable substrate that outlives any single process — and (Gemini's tell) is the value an operator would keep even if they threw away the PTY delivery layer entirely.

**Both name the same north star:** c11 is becoming a **single-host actor runtime where the actors are LLM agents in PTYs, and the mailbox is its message-passing layer.** The framing that unlocks the most is that this is IPC for a local multi-agent OS — surfaces are processes, mailbox is the syscall layer, Lattice tickets are the run-queue, c11 is the kernel. Every §4 vector is an incremental step toward that, and naming it explicitly is what makes the roadmap legible.

---

## 3. How it will actually be used in 3 months

**The dominant, design-serves-it-perfectly pattern (both agree):** fire-and-forget handoffs. Delegators fire "PR open at X / blocked on Y, need a decision" into the orchestrator's PTY; the orchestrator routes decisions back. Claude estimates this is ~80% of real traffic and the design serves it cleanly today. In three months this is the nervous system of every lattice-orchestrator run and the operator barely thinks about it — which is the goal. The framed `<c11-msg>` block between prompts becomes as native to agents as a tool result.

**The operator's own seat is overwatch:** one agent above the fleet, tailing `_dispatch.log` across workspaces, answering "what's the state of everything?" by reading who messaged whom.

**Where the design *fights* real usage — and the two models diverge on which wall hits first:**

- **Request/reply (both flag it).** Served via `reply_to`/`in_reply_to`, but with no correlation timeout and no "the actor I asked is dead/stuck" signal. In an 8-agent session a human notices a hung delegator. In a 30-agent overnight run, nobody does until morning. Gemini calls correlation "difficult at the protocol level"; Claude calls it the first wall after handoffs.

- **Broadcast / fan-out (Claude weights heaviest).** The single biggest *capability* gap per Claude: today you loop over `--to` per name, so the *sender* maintains the recipient list — exactly backwards for a swarm. The operator will reach for **role broadcast** ("all delegators, abort") far more than topic-subscribe, and will be mildly annoyed that planned Stage 3 gives the pull-shaped primitive when they wanted the push-shaped one.

- **Concurrent delivery into a busy PTY (Gemini weights heaviest, Claude underweights).** Gemini's central claim: pasting `<c11-msg>` into an active PTY is *inherently unsafe* — an agent mid-shell-command or in a cooked-mode app (Vim) gets a corrupted input stream and race conditions. Gemini predicts operators abandon the `stdin` handler within three months and tail the filesystem inbox directly, proving the filesystem contract is the real value and the PTY injection is a parlor trick. Claude does not treat PTY injection as a primary failure mode (it trusts the receiver-declared `stdin`-opt-in discipline to contain blast radius).

**What both agree is correctly out of scope:** work-stealing / shared consumable queue. Lattice tickets *are* the work queue; the mailbox is the nervous system. Don't build work-stealing into it. (Claude states this explicitly; Gemini lists work-stealing as a usage pattern but doesn't ask the mailbox to natively own the queue.)

**The 7am moment (Claude's vivid prediction, and the likely first hard feature request):** an overnight run where a delegator renamed itself or died unanswered, the orchestrator sent three messages all rejected-unresolved, kept waiting, and *nothing flagged it*. The mailbox did everything right per contract and the swarm still deadlocked, because the contract has no liveness story. The next mutation that ships is the one that turns that 7am forensic dig into a flagged alert.

---

## 4. Consensus mutation vectors — ranked by leverage

Leverage = unlock / (cost × risk). **[BOTH]** = both models name it; **[CLAUDE]** / **[GEMINI]** = one model.

### 1. Stable address alongside the mutable title — **[BOTH, unanimous #1]**
- **Unlocks:** the bus stops silently partitioning every time an agent renames its tab. Reply chains survive renames. Roles ("delegator", "orchestrator") become stable handles independent of display vanity. **This is the foundation every other reliability mutation sits on** — supervision, group addressing, receipts, and cross-host all assume the address you sent to still exists.
- **Cost:** small. Add an `mailbox.address`/`mailbox.role` key lookup with title-fallback in the resolver; add a `surface:<ulid>` qualifier form mirroring the existing `workspace:*` parsing. `to` is already an opaque string — **no schema change.**
- **Risks:** low. Backward-compatible (title stays the default). Only subtlety is precedence/collision rules, which the existing local-first/ambiguous machinery already models. Gemini frames the upside as eliminating inevitable name collisions in an 8–30 agent swarm; Claude frames it as killing the most insidious *silent* failure mode. Same fix.

### 2a. Liveness as a first-class signal (presence + monitor) — **[CLAUDE, his co-#1]**
- **Unlocks:** the toy→infrastructure jump. `c11 mailbox who` / `resolve --to <name>` returns live/dead + workspace, so an agent can check "is my recipient alive?" *before* it blocks. A monitor/dead-letter-on-close emits an Erlang-style `'DOWN'` (or at minimum a `recipient_closed` event in `_dispatch.log`) so deadlocks become *visible*. For an unattended swarm, visible deadlocks are the whole game.
- **Cost:** medium. Presence is nearly free (exposing data the resolver already computes on every send). Monitor is more — track outstanding correlations or hook surface-close. Start with presence + the log event; defer synthetic `'DOWN'`.
- **Risks:** medium and honest: "alive" (PTY exists) ≠ "responsive" (will process its inbox). Presence answers the first, not the second; don't oversell it. But "the PTY is gone" is a real, common, currently-invisible failure worth catching.

### 2b. Out-of-band delivery socket (replace/supplement stdin PTY paste) — **[GEMINI, his co-#1]**
- **Unlocks:** reliable message ingestion without corrupting the PTY's data plane. Agents can receive while actively working (running commands, editing files) instead of only when idle at a prompt. Per Gemini this is what graduates the mailbox "from a fragile bash-script parlor trick into a robust concurrent actor runtime."
- **Cost:** medium-to-high — a dedicated control socket or named pipe the agent process listens on, plus agent-side wiring to consume it. Note this pushes work into the *agent/skill* layer (the agent must run a listener), which is a different posture than c11 doing the delivery.
- **Risks:** medium. It re-opens "how does a stochastic LLM actor reliably drain a side channel," and it's a larger surface than presence. **This is the load-bearing disagreement — see §5 and §8.**

### 3. Topic / role pub-sub fan-out (Stage 3, planned) — **[BOTH]**
- **Unlocks:** broadcast without the sender enumerating recipients. Essential for overwatch ("report status" to all) and orchestrator ("abort" to all delegators). Claude's sharpening: ship **group/role addressing** (`--to @delegators` → every surface with `mailbox.role=delegator`) *first* — it's cheaper than glob topics (exact match, no glob engine) and is the 80% push-to-role case the operator actually wants over pull-by-topic.
- **Cost:** medium, mostly already scoped; rides the same dispatch-time resolution.
- **Risks:** medium. Fan-out amplifies PTY-injection blast radius — a malformed broadcast hits N agents at once. Receiver-declared delivery discipline contains it, but test under load. (Gemini also flags noisy-neighbor.)

### 4. `_processing/` crash-recovery sweep + ack/receipt — **[BOTH]**
- **Unlocks:** closes the at-least-once crash window (sweep surviving `_processing/*.msg` back to `_outbox/`; receivers dedupe by id, safe by construction). Adding a sender-visible "recipient drained this id" event (distinct from "PTY write ok") closes the "no receipt" gap for the broadcast-stop case.
- **Cost:** sweep is ~20 lines, already specified. Receipt is low-medium (`recv --drain` already unlinks; have it append a `delivered` log event).
- **Risks:** very low for the sweep (dedupe-by-id makes redelivery safe). For receipts, beware scope creep into a full ack/retry protocol — keep it to *observability of consumption*. Critically: "the actor read its mailbox" ≠ "the actor acted." Don't let `delivered` masquerade as `acked`.

### 5. Cross-host / tailnet bridge (Atlas + Hyperion) — **[CLAUDE]**
- **Unlocks:** genuinely new capability — the swarm spans machines; the always-on agentic host becomes addressable from the laptop.
- **Cost:** high. Reopens the deferred security model: `from` is sender-attested, which is fine same-user-same-host and *not* fine across a network boundary.
- **Risks:** high. Don't do this until stable addressing and a real identity story exist. **Name it, don't build it yet.**

### 6. Observability surface (mailbox / overwatch dashboard) — **[CLAUDE; GEMINI as a "wildest"]**
- **Unlocks:** the operator *sees* the swarm's nervous system — who's talking to whom, unanswered requests, rejected sends. Pairs with liveness to make the 30-agent case legible.
- **Cost:** medium (UI on existing logs). **Risks:** low, pure addition. Good fast-follow once liveness exists (a liveness view with nothing to show is just a log tailer).

---

## 5. The leverage points (highest priority)

**One unanimous, one contested.**

1. **Stable address (both models' #1).** Cheapest change, removes the most insidious silent failure, no schema change, and is a hard prerequisite for everything else. There is no debate. Ship it first.

2. **The "second hole" — and here the models split, which is itself the signal.** Both agree stable addressing alone is insufficient for the unattended 30-agent run; they disagree on the second move:
   - **Claude: liveness/supervision** (presence + monitor). Makes invisible deadlocks visible. Lower cost, stays in c11's lane (exposing data the resolver already has).
   - **Gemini: out-of-band delivery** (control socket). Makes concurrent reception safe. Higher cost, pushes a listener into the agent layer.

   **Recommendation:** treat **stable address + liveness** as the one combined leverage move to ship next (Claude's "treat them as one move"), because it is cheaper, stays inside c11's substrate, and directly answers the predicted 7am failure. Hold **out-of-band delivery** as the *contingent* leverage point: if dogfooding shows the stdin handler corrupting busy-PTY agents in practice (Gemini's bet), it jumps to #1 immediately. The disagreement is empirically resolvable in one dogfood session — so resolve it that way rather than picking on priors.

---

## 6. Wildest mutations (name them, mostly don't build yet)

Both models independently surfaced the same three big bets — strong signal these are real, not noise:

- **The `<c11-msg>` block as a standalone, provider-neutral agent-to-agent wire protocol that outlives c11. [BOTH]** Claude calls this the single highest-leverage *idea* in the whole feature and "almost free": the block is LLM-native, transport-agnostic, injection-defended, and has no reason to be c11-specific. Spec `<agent-msg>` as a documented format the way Anthropic ships MCP, and c11 becomes the *reference implementation* of a format rather than the owner of a feature — it could ride Slack, tmux, SSH, any text channel. Given the cmux↔c11 OSS posture and the Stage 11 orchestration thesis, this is the largest-surface, smallest-code mutation: a doc and a name. **Seriously consider it.**

- **The mailbox/`_dispatch.log` as shared swarm memory. [BOTH]** Make message bodies content-addressed (hash → `blobs/`) and the append-only log becomes a replayable, dedupable, shared episodic memory the swarm can query ("what did anyone learn about the socket bug?"). Gemini's sharper version: agents bootstrap context on restart — "what did I miss while I was asleep?" — turning the mailbox into the substrate for context recovery after a reload/compaction.

- **The human as a first-class mailbox address. [BOTH]** `c11 mailbox send --to operator` surfaces in the sidebar/notification; the operator replies into the bus. The overwatch agent already wants to be "the one agent you talk to." Make the human an addressable node and the bus becomes the single coordination plane for human + swarm, not two systems bolted together. Gemini's framing adds intercept/approve/modify/inject — a human-in-the-loop control surface over the swarm.

Claude-only further bets: **the mailbox as the kernel of a local multi-agent OS** (the organizing metaphor for all of §4), and **self-organizing topologies** (once role-addressing + presence exist, agents form their own coordination graphs — don't build it, *enable* it and watch).

---

## 7. What to remove / simplify (evolution as subtraction)

Mostly Claude's catalog; Gemini contributes two of his own (one of which is a genuine disagreement — see §8).

- **The `watch` handler / `c11 mailbox watch` stub. [CLAUDE]** Throws "not implemented; see tail." A command that exists only to error is worse than no command. Kill it or alias it to `tail`. The three-handler vision (`stdin`/`silent`/`watch`) is cleaner as two + `tail` for streams. **Remove.**

- **`body_ref` accepted-but-not-read-through. [CLAUDE]** The dispatcher validates and stores it but nobody reads it. A half-primitive that *looks* like a feature and implies a guarantee c11 doesn't make. Either finish read-through (with `blobs/` allowlist) or demote it to a documented sender convention and stop validating it as if c11 owns it. The current middle state is a maintenance trap.

- **Accepted-but-ignored envelope fields (`content_type`, `ttl_seconds`, `ext`). [CLAUDE]** Don't remove them (forward-compat hooks; `ext` is the escape hatch), but **audit the validator's job**: validate *shape*, stop implying *behavior*. `ttl_seconds` especially reads like "c11 expires this" — it doesn't. One sentence per ignored field at the point of use: "advisory; c11 does not act on this."

- **Collapse the nested 2s/500ms reporting timeouts. [CLAUDE]** The `ContinuationGate` + double-Task race + semaphore is the most over-built corner relative to the risk — both timeouts are explicitly "reporting bounds, not runtime bounds" and neither can interrupt a blocked main-thread write. Accepted complexity *for now*; collapse to one bound the moment a genuinely async-cancellable PTY writer lands.

- **Simplify the local-first cross-workspace routing rules. [GEMINI]** Gemini calls local-first → single-workspace → ambiguous "too clever and unpredictable" and wants strict `--to-workspace` disambiguation whenever names aren't globally unique. **Note:** this *directly contradicts* the recently-merged #251 direction, which Claude praised as the right increment. Flag, don't action — see §8.

- **Remove the `silent` delivery handler. [GEMINI]** Gemini reads it as a debug artifact leaking into production. **Claude implicitly disagrees** — he treats receiver-declared delivery discipline (including silent) as the *load-bearing* safety mechanism that contains PTY-injection blast radius. This is a real divergence, not a clerical one — see §8.

---

## 8. Dissent / divergence — and which signal is more interesting

*With Codex absent, every disagreement below is a clean 1-vs-1 with no tie-breaker. Weight accordingly.*

**The headline divergence — what is the second hole, and is the stdin PTY delivery safe?**

This is the most interesting disagreement in the pack, because the two models are looking at the *same mechanism* and reaching opposite verdicts:

- **Claude trusts the PTY delivery.** "Doorbell, not delivery" — he treats the receiver-declared `stdin`-opt-in discipline as sufficient containment, and the in-practice-microseconds write as a non-issue. His second hole is **liveness**: the mailbox can deliver to an actor that never processes, and nothing tells the sender.

- **Gemini distrusts the PTY delivery fundamentally.** Pasting into an active PTY is *inherently unsafe* under concurrency; he predicts operators will abandon the `stdin` handler within three months and tail the filesystem directly. His second hole is **delivery safety** (out-of-band socket).

**Which is the more interesting signal? Gemini's.** Not because he's necessarily right — Claude's liveness gap is more certain to bite, and the 7am-deadlock story is concrete and design-grounded. But Gemini's claim is the more *consequential if true*, and it's the one that challenges a load-bearing design assumption rather than adding a missing capability on top of it. If Gemini is right that busy-PTY corruption is real in practice, then a chunk of the feature's value (the terminal integration) is a liability and the filesystem contract is the only durable asset — which would reframe the whole roadmap. Claude's gap is additive (build liveness on top of a sound base); Gemini's gap is subtractive (a core mechanism may be unsound). **The subtractive claim is the more interesting signal precisely because it's the one that, if validated, changes the most — and it is cheaply testable: run a dogfood session that fires messages into agents mid-Vim/mid-build and watch for corruption.** Do that test before committing to either second-leverage path.

**Secondary divergences:**

- **`silent` handler: keep (Claude) vs remove (Gemini).** Claude's read is more credible here — silent is part of the receiver-decides delivery contract that Gemini *also* implicitly relies on when he says "if a surface doesn't want messages it shouldn't be addressable." Gemini's "reject instead" still requires a per-surface opt-out, which is what silent *is*. The disagreement may be terminological, but Claude's framing (silent as load-bearing safety, not debug cruft) is the sounder one.

- **Cross-workspace routing: keep local-first (Claude) vs strict disambiguation (Gemini).** Claude explicitly praised #251 (non-silent rejection + cross-workspace) as the right increment; Gemini wants to roll back its cleverness. **This one should not be actioned without the operator** — it's a direct reversal of just-merged, deliberately-chosen behavior, and Gemini's objection ("too clever") is an aesthetic call, not a demonstrated failure. Stable addressing (§4 #1) substantially defuses the collision problem Gemini is worried about anyway, which argues for Claude's side: fix identity, keep the convenience routing.

**Where they fully agree (high-confidence, act on these):** actor-model framing; stable addressing as #1; envelope is done (don't enrich it); the three wildest bets (standalone wire protocol, shared-memory log, human-as-address); topics/role fan-out and crash-recovery sweep as planned mid-tier work; and the core verdict — **enough as a primitive, not enough as unattended infrastructure, gap is small.**
