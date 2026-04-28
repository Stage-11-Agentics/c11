# Evolutionary Plan Review: Conversation Store Architecture

**Plan:** `conversation-store-architecture`
**Reviewer model:** Claude (Opus 4.7)
**Review type:** Evolutionary
**Date:** 2026-04-27 20:25

---

## Executive Summary

The plan as written solves a session-resume bug. But the *primitive* it introduces — a TUI-agnostic, persistable, kind-tagged pointer to "a continuation of agent work," owned by c11 rather than by any TUI — is the most strategically valuable thing c11 has shipped since the Ghostty embed. **It is not really a session-resume fix. It is c11 taking ownership of the agent-conversation as a first-class object in the operator-and-agent workspace.** Every TUI vendor presently owns the conversation; c11 has been a passive viewport. After this lands, c11 owns a normalised view of "the work in flight," indexable, addressable, scriptable, portable.

The biggest opportunity is to recognise that and design the primitive *for that future*, not just for the resume bug. Concretely: the `Conversation` object should be on the c11 socket and CLI from day one as a queryable entity (not just a side effect of restore), and the on-disk format should be content-addressable enough that a future "fork this conversation," "tee this conversation to another pane," or "send this conversation to a Lattice ticket" all become trivially expressible. The plan touches all of this in passing ("future global index, future history, future remote") but treats it as out-of-scope. I think the seam is ~80% of the value and the seam is what's at risk if the v1 implementation is shaped narrowly around resume.

The second-biggest opportunity, and the one most at risk of being dropped because it's not on the explicit list: **conversations as the substrate for cross-agent coordination**. Once c11 has a typed handle on every running TUI's conversation, the operator-and-agent pair stops being eight orchestrator-driven sub-agents and starts being a conversation graph. That's the c11 differentiator nobody else can ship.

---

## What's Really Being Built

The plan calls it "a Conversation primitive decoupled from any specific TUI process." That's accurate but understated. Let me name what it actually is at three levels of abstraction:

**Surface level:** A registry-and-strategy pattern that resolves the per-TUI-wrapper sprawl by inverting ownership — c11 keeps the durable state, TUIs feed signals.

**Architectural level:** c11 is acquiring a typed, persistent model of "what work is in flight" inside its workspaces — independent of the process that's currently rendering that work. The TUI becomes a *view* over the conversation, not the conversation itself. This is the same move tmux made (PTY survives shell death) but at a different layer (logical conversation survives PTY death, process death, and machine death).

**Strategic level:** c11 stakes a claim on **being the agent-system-of-record**. Today, "what is Claude doing in this pane?" is answerable only by Claude. After this, c11 holds a normalised handle and routes resume, capture, and (eventually) inspection through itself. That is the position from which orchestration features become possible — without it, every coordination feature has to negotiate with N TUI vendors. With it, coordination features speak one schema c11 owns.

Two phrasings to keep in mind through the rest of the review:

- The plan says "conversation store." I'd argue **conversation graph** is the more accurate description of where this goes. v1 ships a flat per-surface map; the data shape (`SurfaceConversations { active, history }`, `kind` namespace, opaque ids) is already a graph in latent form.
- The plan treats `ConversationStrategy` as a Swift implementation detail. It's actually **the c11 ↔ TUI integration contract** — the declarative shape of "how does an external TUI become legible to c11?" Worth elevating in the doc and the public skill.

The plan is best understood as building **the surface area c11 will negotiate with every future agent system through**. The bug is the prompt; the integration contract is the prize.

---

## How It Could Be Better

These are restructuring suggestions, not polish. Each addresses a way the plan could compound more rather than just fix the immediate failures.

### 1. Promote `Conversation` to a first-class CLI/socket noun on day one

The plan ships `c11 conversation push|claim|tombstone|list|get|clear`. Good. But these are framed as wrapper plumbing — the strategy talks to them, agents don't. **The next step is "agents talk to them too."**

Proposal: ship a fuller verb set in v1, even if some commands are stubs:

```
c11 conversation list [--kind <k>] [--workspace <id>] [--state <alive|suspended|tombstoned>] [--json]
c11 conversation show <id> [--json]                 # full ref + payload + provenance
c11 conversation tag <id> <name>                    # operator-friendly handle ("brand-redesign")
c11 conversation rename <id> <name>
c11 conversation watch <id>                         # streams state transitions to stdout
c11 conversation tail <id>                          # reads transcript via strategy.tail
```

The `tag`/`rename` pair is small but unlocks a huge UX: the operator can `c11 conversation list --tag brand-*` and find every running agent on a multi-pane brand task. This is exactly the surface area Lattice tickets benefit from when they delegate sub-tasks across panes.

The cost is small (CLI parsing + `ConversationStore.tag` mutation). The unlock is operator-and-agent ergonomics that nothing else in the c11 stack provides today.

### 2. Make `kind` namespaced, not flat

The plan uses flat strings: `claude-code`, `codex`, `opencode`, `kimi`, `claude-code-cloud`. Two latent problems:

1. **Versioning.** When Claude Code 3.0 ships and breaks the SessionStart payload, you need `claude-code` and `claude-code-3` simultaneously during transition. Flat strings make that a renaming exercise.
2. **Multi-tenancy.** A future "Anthropic SDK App embedded in the operator's own script that emits c11 conversation events" needs a kind. So does a Lattice agent. So does a custom Python script the operator writes for a one-off task.

Proposal: namespace the kind as `vendor/product[@version]`, e.g., `anthropic/claude-code`, `anthropic/claude-code@3`, `openai/codex`, `c11/markdown-pane`, `stage11/lattice-agent`, `user/<custom-kind>`. The store stays opaque; the strategy registry resolves the kind by exact match first, then by `vendor/product` fallback (drop `@version`), then declines.

This is a 5-minute change at v1 with significant downstream payoff. Doing it later is a migration.

### 3. Pull-scrape is a strategy, not a built-in

The plan describes pull-scrape as if it's a c11-internal capability the strategy *uses*. But scraping a TUI's session storage layout is intimate, fragile, and TUI-specific. Make it the **strategy's job entirely** — c11 just calls `strategy.captureFromDisk(surface)` on a schedule, and the strategy decides what to do (or returns nil if it has nothing).

Why this matters: the moment you make pull-scrape a c11-built-in with structured params (`directory`, `glob`, `cwd-filter`), you've baked in a model of how TUIs store sessions that some future TUI will violate. (E.g., a TUI that uses SQLite, or stores in `~/Library/Application Support`, or uses a remote sync system.) Move the decision into the strategy and you've kept the integration contract clean.

This is a documentation and shape change, not a deletion. The Codex strategy still does exactly what the plan describes — but it owns the file-system code, not c11.

### 4. Decouple "resume on c11 launch" from "the conversation is alive"

The plan implies these are the same thing — `state = .suspended` means "auto-resume on launch." But there are obvious cases where they diverge:

- The operator launched c11 with a one-off `--minimal` flag and doesn't want auto-restore.
- The conversation was `alive` 6 weeks ago in a workspace the operator hasn't opened since. They don't want it auto-resumed when they open that workspace, just made *available* in a "resume previous conversations" picker.
- The agent is a long-running batch job and the operator wants explicit confirmation before re-running it.

Suggestion: split the dimension. `ConversationState` is *what happened to the work* (alive / suspended / tombstoned / unknown). A separate `ResumePolicy` (per-surface or per-conversation) is *what c11 should do about it on launch* (auto / prompt / manual / never). v1 ships only `auto` and `never` (the existing global `CMUX_DISABLE_AGENT_RESTART` becomes per-surface) but the seam is there.

The existing plan can't grow to support "resume picker UI" without retroactively splitting these dimensions. Doing the split at v1 costs a few enum cases and keeps the door open.

### 5. The `unknown` state is doing too much work

The state machine has `unknown` as the resting state after a crash, expected to be resolved by pull-scrape. That collapses two distinct conditions:

1. "I have a ref but I haven't checked if its on-disk session still exists yet." (Unverified after crash recovery — the plan's case.)
2. "I have a ref whose `kind` no strategy is registered for." (Unrecognized kind, mentioned in open question 4.)

These deserve different states. The first is *transient* and wants to resolve itself. The second is *terminal until c11 ships a strategy update*. Conflating them means a snapshot from c11 0.50 (which had `claude-code-3`) loaded into c11 0.45 (which doesn't) gets indistinguishable handling from a perfectly recoverable crashed session.

Suggestion: `unverified` (transient, post-crash) and `unsupported` (no strategy registered for the kind). The store carries `unsupported` refs forward unchanged; on a future c11 release with the missing strategy, they auto-promote to `alive` or `tombstoned`. This is forward-compat insurance for almost no cost.

### 6. `replayPTY` is a Trojan horse and should not ship in v1

Open question 8 asks whether to keep it. I'd say **no**. Once it's in the API, the next plausible feature request ("replay last 200 lines of scrollback when resuming") will land it. PTY replay against arbitrary TUIs is a recipe for control-character bleed-through, mojibake on partial UTF-8, and screen-state desync that will be debugged for months. Cut it from v1; if a v2 use case appears, design for that specific use case rather than ship a generic primitive that invites misuse.

### 7. The "store mutations under a serial queue" call deserves to be an actor

Open question 11 asks. The answer is yes — make it a Swift actor (`ConversationStore: actor`). Reasons:

- The data shape (per-surface map mutated from socket handlers, autosave timer, main actor) is exactly what actors were designed for.
- c11 is gradually moving to actor isolation per the question's framing; this is a clean greenfield site for that move.
- The "capture/resume strategy calls happen outside the lock" rule the plan describes is exactly what actor reentrancy + nonisolated functions express idiomatically.
- The CLI surface gives you a natural test seam: every CLI command is one `await store.<verb>(...)` call.

Doing it with a dispatch queue works but ages into a known migration target. Doing it with an actor lands on the destination directly.

### 8. The `shutdown_clean` flag should also encode *when* the clean shutdown happened

One-byte file works for the binary clean/dirty signal. But "the snapshot was clean as of 2 hours ago, then we crashed in the next session" is a useful thing to know, and the plan's logic doesn't distinguish "clean shutdown the immediate prior run, then crash this run" from "clean shutdown the immediate prior run, no crash this run, you're just doing crash-recovery for paranoia."

Suggestion: write the timestamp of the clean shutdown into the file, and on launch compare it to the snapshot's `capturedAt`. If they're more than ~10s apart, *something* happened between snapshot write and shutdown — even if the file exists. Treat as crash-recovery anyway. Tiny insurance against the sequence "snapshot writes, system sleeps, sleep-kill takes the c11 process, the file got there but it lies." This is cheap. The full crash-recovery path runs; if there's nothing to do, no harm done.

---

## Mutations and Wild Ideas

These are non-incremental. Some are bad ideas. The interesting ones are worth naming.

### Mutation 1: Conversations as a Lattice content type

c11 is a Stage 11 project. Lattice is the agent-readable coordination primitive across Stage 11. Right now they barely touch each other. **What if every c11 conversation auto-creates a Lattice artifact** (or, more carefully, gets *offered* a Lattice artifact handle when the operator wants to track it)?

Concretely: `c11 conversation tag <id> --lattice <ticket-id>` files the conversation as work-in-progress on a ticket. The operator's Lattice dashboard then shows "Atin has 4 active conversations against C11-24, in workspace c11-dev, last activity 3 minutes ago." When the conversation tombstones, the artifact updates with the final state. When the conversation is resumed in a new pane, the artifact tracks the move.

This is a natural binding because both systems are agent-native and operator-and-agent-shaped. The lift on the c11 side is a single CLI verb and an optional payload field. The lift on the Lattice side is a content-type definition. The result is "conversations and tasks as the same fabric" which is exactly the operator-and-agent thesis Stage 11 is building toward.

### Mutation 2: Conversation as the unit of cross-pane communication

Today, agents in c11 panes coordinate by `c11 send` (raw text into another pane's PTY) or by writing to shared markdown / Lattice. Both are out-of-band and brittle.

What if conversations were addressable enough that one agent could *cite* another? `c11 conversation show <id>` gives you the conversation handle; `c11 conversation tail <id>` gives you the live transcript; the strategy could expose `lookup(query)` to find conversations by content. Now agent A can say "see the analysis in conversation `cnv_01KQ...`" and agent B can fetch it without the operator playing carrier pigeon.

This is the kind of feature that's borderline impossible without the primitive but obvious once you have it. It also feeds back into Mutation 1 — Lattice artifacts that *are* conversation references stop being snapshots and become live windows.

### Mutation 3: Conversation forking

The Strategy interface implies a `resume(surface, ref) -> ResumeAction`. What if it also offered `fork(surface, ref) -> ResumeAction` — start a new conversation seeded with the prior conversation's context? Claude Code supports this explicitly (`--resume <id>` re-opens; you can also `claude` with the conversation file's transcript to seed). Codex doesn't, but a strategy could fake it by piping the transcript JSONL into the prompt.

This unlocks the "I want to try a different approach from this point" workflow that operators currently do by hand: copy-paste from the old pane, open a new pane, paste, edit. With `c11 conversation fork <id> --in-new-pane`, that's two seconds.

It also does something subtle: it makes conversations the unit of *exploration*. The operator who's using c11 as a parallel-agents environment isn't running 10 different conversations — they're running 10 forks of one investigation. Conversations-as-DAG is the latent shape; this is the explicit move.

### Mutation 4: Time-travel conversations

Once you have `history: [Ref]` populated, you have the building block for "rewind this conversation to its state 20 minutes ago." Most TUIs don't support this natively — Claude Code, for example, doesn't let you rewind a session — but c11 *could* if it kept periodic ConversationRef snapshots tagged with timestamps. The `Ref` already has `capturedAt`; the strategy already knows how to resume from a specific id. The extension is "the strategy tracks intermediate refs and resume can target any of them."

This is genuinely speculative. Most TUIs would need protocol changes to support mid-conversation rollback. But the *seam* — keeping a list of refs over time and allowing resume from any — costs nothing in v1 if you preserve the `history` field and let it grow. The plan already commits to that.

### Mutation 5: Conversations on the operator's iPhone

`ConversationRef.kind` and `id` are opaque. A `claude-code-cloud` strategy already implies remote resume. What about `claude-code-mobile`? The operator's iPhone has a c11 mobile app (today: nothing, but Stage 11 ships Aurum on iOS — the appetite is there) that surfaces "your active c11 conversations" and lets you append a one-line message via voice. The mobile app isn't running the TUI; it's appending to the conversation, which c11 desktop picks up next time the workspace opens.

This is far-future, but it's a natural extension of "the conversation lives in c11, not in the TUI." Once the conversation is the durable object, the surfaces over it can be anywhere.

### Mutation 6: Conversation diffs as the primitive

Possibly the most interesting and most off-script. What if a conversation is internally a sequence of *deltas* (user message, agent message, tool call, tool result), and `ConversationRef.id` is content-addressed by the hash of the delta sequence? Every fork is a new hash; every resume re-extends a hash chain.

This makes conversations git-shaped: you can branch, merge (more carefully), diff, and replay any prefix. It's also how you'd build a "show me what the agent decided to do at this fork point" debugger. Most TUI vendors don't expose delta-level access — but you could *adapt* their session files into a delta sequence at the strategy boundary, and once you have that, the delta sequence is portable across TUIs.

Probably too ambitious for v1. Possibly the right direction for v3 if c11 wants to differentiate from "yet another terminal multiplexer" and become "the system of record for agent work."

### Mutation 7: Conversations as an MCP server

c11 already runs a socket. The conversation API is essentially a query-and-mutation interface to a typed object store. Wrap it in MCP and expose it as a tool to the agents *running inside the panes*. Now Claude inside pane A can call a tool that reads the live transcript of Codex inside pane B. Cross-agent reasoning becomes a tool call instead of a prompt-engineered shared-doc dance.

This one is short to ship if you have the underlying primitive: it's a CLI-to-MCP adapter (which Stage 11 has built before) on top of the verbs Mutation 1 already implies.

---

## What It Unlocks

Once the conversation primitive is real, here's what becomes possible — much of which the plan declares "out of scope" but which gets significantly cheaper to build later because of design decisions made now.

| Capability | Why it's now possible | Cost after vs. before |
|---|---|---|
| "Resume past conversations" picker UI | `history` field exists in v1 | Days vs. months |
| Conversation search ("find the agent that talked about Stripe webhooks") | Strategy can expose `tail`; central index of refs | Weeks vs. impossible-without-rewriting |
| Cross-pane agent citation (Mutation 2) | Conversations are addressable | Days vs. months |
| Lattice ↔ c11 binding (Mutation 1) | Both have stable per-conversation handles | Single afternoon vs. weeks |
| "Resume this conversation in the cloud" | `kind` namespace allows `claude-code` and `claude-code-cloud` to coexist | Cheap vs. architectural surgery |
| Conversation provenance for security audits | `capturedAt` + `capturedVia` recorded for every ref | Built-in vs. requires retrofit |
| Diff-based debugging across c11 reboots | Snapshots embed conversation state; deltas implicit | Possible vs. lost forever |
| Operator-marked checkpoints (Approach D, deferred) | `manual` capture source already in enum | Days vs. days, but no migration |
| Multi-machine conversation portability | Refs are opaque + payload-extensible | Weeks vs. needs a new schema |
| Agent-to-agent coordination via conversation graph | Refs are queryable, taggable, addressable | Significant unlock |

The thing to notice: **most of these are cheap *because* of the v1 shape**, not despite it. The plan's "out of scope" list is largely "things that v1 enables but doesn't ship." That's the right shape. The risk is that the v1 shape gets simplified during implementation (history field omitted, payload field cut, namespace deferred) in ways that close those doors.

The single highest-leverage thing the reviewer can do is enforce that the v1 *shape* survives implementation review even when individual fields look unused — they are options on the future, and options are valuable even when unexercised.

---

## Sequencing and Compounding

The plan implicitly orders work as: schema → store → strategies → CLI → wrappers → snapshot integration → tests → ship. Reasonable. Here's where I'd push.

### Move CLI verbs up

The plan says "wrappers shrink to declare the kind." Good. But the CLI verbs the wrappers will call are the same verbs operators and agents will use — yet the plan treats CLI as a *consequence* of the store, not a co-equal first concern. **Build the CLI surface before the strategies.**

Why: the CLI is the operator-and-agent integration contract. Designing it first surfaces shape problems the internal data layer never would. (Example: if you only think about it from the strategy side, you might not realize that `c11 conversation list --json` needs to project the `payload` carefully because the field is heterogeneous across kinds.) Designing it first also gets the skill-doc contract written early, which means agents can start using conversations the day v1 ships rather than the operator hand-rolling adoption.

Rough order:

1. **Schema** (`ConversationRef`, `SurfaceConversations`) — already in plan.
2. **CLI verbs** (full set, even stubs that error "not implemented") — promote earlier than plan.
3. **Skill update** for the c11 SKILL with the new verbs and patterns. Drop into `skills/c11/SKILL.md` with examples.
4. **Store** with actor isolation.
5. **Claude strategy** (most complex, has both push and pull). Working end-to-end on this kind only.
6. **Snapshot round-trip** for the single-kind case. Prove restore works.
7. **Codex strategy** (proves the no-hook case).
8. **Opencode + kimi strategies** (proves the no-resume-flag case).
9. **CLI verbs filled in** for the operator-facing set (list/show/tag/etc.).
10. **Crash recovery + `shutdown_clean` flag**.
11. **`pendingRestartCommands` refactor** away from `AgentRestartRegistry`.

### Defer pull-scrape until the push path is proven

The plan describes pull-scrape as "fallback + crash recovery primary." But it adds a non-trivial scrape implementation to every strategy in v1, and the first cohort of bugs you'll encounter are in the scrape paths (filesystem race conditions, partial writes, vendor session-file format drift). Suggestion:

- v1 ships push-only for Claude (already the working path) and wrapper-claim-only for Codex.
- Crash recovery in v1 is "use whatever push values are in the snapshot; if they're stale, the operator's first message in the resumed session reveals it."
- Pull-scrape lands in v1.1, after the push path is rock-solid.

Rationale: the plan's worst failure mode is "we ship a complex new architecture and it has a different bug than the bug it replaced." Cutting pull-scrape from v1 reduces the new-bug surface area dramatically. The crash-recovery story is degraded but no worse than today's.

The plan author may push back here — pull-scrape is genuinely the answer to the codex-multi-pane bug. Counter-counter: codex-multi-pane bug v1 fix can be "wrapper claim with cwd is enough to disambiguate when cwds differ; document the same-cwd case as a known limitation." Then pull-scrape is purely an enhancement, not a load-bearing structural change.

### Sequence the held release smartly

Open question 10 mentions PR #94 (the held 0.44.0). The plan currently implies "stack the conversation-store onto #94." That makes the release window late and the PR enormous. Alternative:

1. **Ship #94 as-is now** with the existing per-TUI wrapper pattern as a 0.44.0. It works for Claude, sort-of works for Codex. The remaining bugs are documented in the changelog as known limitations.
2. **Conversation-store ships in 0.45.0**, no held release blocking on it.
3. The 0.44.0 changelog says "session resume is preview-quality; 0.45 will replace this with a proper architecture." Sets expectations correctly.

Why: bundling architectural rewrites with held releases is how releases slip by 2x. Decoupling them lets the architecture get the breathing room it needs without operators waiting on a stuck release.

This is a release-management call, not a technical one. Worth the operator's explicit yes/no.

---

## The Flywheel

There is a flywheel latent in this plan. The plan author may not have noticed it explicitly. Here it is:

```
        ┌──────────────────────────────────────────┐
        │ More TUI integrations land               │
        │ (each adds a ConversationStrategy)       │
        └────────────────────┬─────────────────────┘
                             │
                             ▼
        ┌──────────────────────────────────────────┐
        │ Conversation primitive becomes more      │
        │ universal — covers more of the operator's│
        │ agent fleet                              │
        └────────────────────┬─────────────────────┘
                             │
                             ▼
        ┌──────────────────────────────────────────┐
        │ Higher-level features built on the       │
        │ primitive (Lattice binding, search,      │
        │ forking, cross-pane citation) become     │
        │ more valuable, because they cover more   │
        │ of the operator's surface area           │
        └────────────────────┬─────────────────────┘
                             │
                             ▼
        ┌──────────────────────────────────────────┐
        │ Operator and agents adopt c11 more       │
        │ deeply because the value is in the       │
        │ aggregation, not any single feature      │
        └────────────────────┬─────────────────────┘
                             │
                             ▼
        ┌──────────────────────────────────────────┐
        │ More TUI vendors / agent systems want    │
        │ to play well with c11 — easier to build  │
        │ a strategy than to build their own       │
        │ multiplexer                              │
        └────────────────────┬─────────────────────┘
                             │
                             ▼
                       (back to top)
```

The flywheel turns when the primitive is stable, the integration contract (Strategy + CLI verbs) is documented, and the per-TUI rollout is *easy*. Two strategies a year is too slow; two a month is alive. The plan's "a new kind is one Swift file" claim needs to be load-bearing.

**To accelerate the flywheel:**

1. **Ship a "how to write a ConversationStrategy" doc as part of v1.** Not in some future docs pass — in the v1 PR. Without this, every new strategy is reverse-engineered from existing ones, which slows the contributor (whether that's the operator, an agent, or an external user).

2. **Consider a "user-defined kind" path.** Mutation 1's `user/<custom-kind>` is the trigger. If the operator can `c11 conversation push --kind user/atins-custom-script --id whatever` from a one-off Python script and have c11 track it, the primitive becomes useful long before there's a built-in strategy for that kind. The operator ships their own strategy (or a no-op resume) and now c11 is tracking their custom workflow.

3. **Build a public "conversation feed" API early.** Even a stub that emits state transitions over the socket lets external tools (Lattice dashboards, the operator's own scripts, future AI hosts) react to conversation events. This is the connective tissue that turns "conversations exist" into "conversations are how things coordinate."

4. **Budget time for the next two strategies, not just the first one.** When Claude's strategy ships, immediately follow with codex (different shape: no hooks) and a deliberately-weird third one (e.g., a markdown surface tracked as a "conversation" with the operator). Three strategies prove the contract is real; one proves nothing.

The plan does *not* currently treat the integration contract as a public artifact. That's the highest-leverage change to make the flywheel actually spin.

---

## Concrete Suggestions

A short list of specific, actionable proposals — sorted by ratio of payoff to effort.

### S1. Adopt namespaced kinds (`vendor/product[@version]`) at v1
5 minutes of design, prevents a future migration. Makes versioning, multi-vendor, and user-defined kinds free.

### S2. Promote `Conversation` CLI verbs to ship in v1
Even as stubs. The `tag`, `rename`, `show`, `watch`, `tail` verbs are the operator-and-agent UX seam. They cost a day of CLI work and a paragraph in the skill, and they unlock the flywheel.

### S3. Make `ConversationStore` a Swift actor
Open question 11's answer is yes. Lower long-term migration burden, cleaner code, idiomatic.

### S4. Split state and resume policy
Don't conflate "what's the conversation's lifecycle status" with "should c11 do anything about it on launch." `ConversationState` × `ResumePolicy` is the right shape.

### S5. Drop `replayPTY` from `ResumeAction` enum
Premature, dangerous, and invites future misuse. Remove it; let v2 design for the specific use case if any appears.

### S6. Encode timestamp in `shutdown_clean` flag
One line of extra code, much better crash-detection signal. Defends against the "snapshot wrote, then we sleep-died, then we re-launched" sequence.

### S7. Defer pull-scrape from v1; ship push-only
Cuts new-bug surface area in half. Pull-scrape lands in v1.1 once the push path is rock-solid. Codex same-cwd degenerate case is documented as a known limitation in v1, not a structural concern.

### S8. Ship a "how to write a Strategy" doc with v1
The integration contract is the prize. Document it explicitly in `docs/conversation-strategies.md` (or similar) at v1. Every future strategy reduces in cost as a result.

### S9. Don't bundle the rewrite with PR #94
Ship #94 as-is for 0.44.0 with documented limitations; ship the conversation store in 0.45.0. Decouples architectural risk from release-window risk.

### S10. Build a `conversation feed` socket subscription
Even if no UI consumes it in v1, exposing state transitions over the socket means external tools (Lattice, operator scripts, MCP servers) can react. This is the connective tissue Mutations 1, 2, 7 all depend on.

### S11. Add `unsupported` state for kinds with no registered strategy
Distinguishes "we crashed and need to verify" (transient `unverified`) from "this snapshot was written by a future c11 with a strategy we don't have" (terminal-but-recoverable `unsupported`). Cheap forward-compat.

### S12. Make pull-scrape a strategy method, not a c11 built-in
Even when v1.1 ships pull-scrape, it should live on the strategy. Gives the strategy full control over how its TUI's session storage is interrogated. Avoids c11 baking in assumptions about storage layout.

### S13. Reserve `payload` keys with a small registry
The `payload: [String: PersistedJSONValue]` field is heterogeneous and per-kind. To avoid namespace collisions and key drift across strategies, document a small set of conventional keys (`cwd`, `model`, `transcriptPath`, `lastUserMessageAt`, `tokensUsed`) that any strategy *may* use, and reserve unprefixed keys for those. Strategy-specific keys go under `<kind>.foo`. This is a 2-paragraph convention in the docs that prevents 6 months of strategy-implementation drift.

### S14. Allow `c11 conversation claim --kind c11/markdown-pane`
Treating markdown surfaces as a degenerate kind of conversation is provocative but coherent — the conversation is between the operator and the document. It exercises the `kind` system, surfaces collisions early, and unlocks "show me my last edited markdown surface" via the same machinery as agent resume. Optional but worth thinking through.

### S15. Fingerprint the c11 instance in the snapshot
Mention `instance_id` (per-c11-install UUID) in the snapshot so multi-host scenarios (cloud sync of `~/.c11/`, multiple developer machines) don't conflate two operators' conversations. v1 ships single-host but reserving the field is free.

---

## Questions for the Plan Author

These are decisions and clarifications that would unlock the most evolutionary potential. The plan should answer them before implementation.

1. **Is the conversation primitive intended to become a public, queryable, agent-facing object — or is it strictly an internal implementation detail of session resume?** The plan reads as the latter. The flywheel argument says it should be the former. The answer changes scope significantly.

2. **What is the relationship between `Conversation` and Lattice artifacts?** Stage 11 has another agent-native primitive in Lattice; binding them at v1 (Mutation 1) is a small lift with large payoff. Is there a reason not to?

3. **Are you willing to ship the v1 with `kind` namespacing (`vendor/product[@version]`)?** The cost is 5 minutes; the avoided cost is a future migration. I would recommend yes unconditionally.

4. **What's the target for "number of strategies shipped in v1"?** The plan says "one Swift file per kind." If v1 ships 4 strategies (claude, codex, opencode, kimi) and they're all hand-shaped differently, the contract isn't proven. Suggest a target of 3 with deliberate variety: one with hooks (claude), one without (codex), and one that's intentionally weird (markdown? operator-script?). This stress-tests the abstraction.

5. **Is the conversation store going to be on the c11 socket from day one, or is it a CLI-only thing?** Socket exposure unlocks MCP, dashboards, agent-to-agent citation. CLI-only forces every external tool to shell out. I lean strongly toward socket, with CLI as a thin client.

6. **PR #94 release management: bundle or sequence?** If the architectural rewrite blocks the held release, the release window stretches. Sequencing them means 0.44.0 ships imperfectly and 0.45.0 fixes it properly. Operator's call but worth being explicit.

7. **What's the recovery story for "the snapshot points to a kind we don't have a strategy for"?** Plan's open question 4 asks this. My answer is `unsupported` state, retain ref unchanged, auto-promote on future strategy-shipping releases. Confirm direction.

8. **Is there appetite for a "user-defined strategy" path?** Mutation/S14 territory. If yes, design v1 to allow it; if no, document why and close that door explicitly. Either is fine, but indecision is the worst case.

9. **What's the contract with `c11 send`?** Today, `c11 send` types arbitrary text into a pane. After conversation primitives exist, "send a message to a conversation" is a more semantically rich operation than "send keystrokes to a PTY." Should `c11 conversation message <id> "..."` exist as a higher-level alternative, dispatched per-strategy? (Claude: writes to the prompt buffer with submit. Markdown: appends a section. Custom: strategy-defined.) This is far-future but the seam is decided here.

10. **Will the conversation API be exposed over MCP at any point?** Mutation 7 territory. An MCP server that wraps the conversation API turns "agents inside c11 panes" into "agents that can reason about each other." This is potentially the largest single unlock for operator-and-agent workflow. Worth flagging early.

11. **Is the plan author committed to documenting the integration contract publicly?** The plan today says "a new kind is one Swift file." Without a doc that says *what shape the file takes, what guarantees the strategy provides, and what c11 promises in return*, that claim is aspirational. Public documentation of `ConversationStrategy` is the difference between "fork-only contributors" and "any operator can extend this." Which world are we in?

12. **What's the test fixture story for strategies?** Plan mentions "fixture session-storage layouts." Are these checked into the repo? Are they synthesised at test time? If a TUI vendor changes their storage layout, do tests catch it or do they pass-but-fail-in-production? This shapes the cost of every future strategy.

13. **Is there interest in a `conversation diff` / `conversation export` primitive in v1.x?** Mutation 6 territory. Even if not shipped, the on-disk format decisions (especially how `payload` is structured and whether the strategy can cheaply derive a delta sequence) determine whether this becomes possible later. Consider during implementation whether to leave headroom.

14. **Is the operator the primary user of this primitive, or are agents?** Both, obviously. But the *primary* changes the design priorities. For agent-primary, MCP exposure and machine-readable verbs matter most. For operator-primary, the CLI ergonomics and skill doc matter most. The plan today implicitly weights toward neither and would benefit from an explicit prioritization.

15. **What's the deprecation story for the existing `claude-hook` CLI surface?** Open question 3 asks about routing. The deeper question: at what point does `c11 claude-hook session-start` cease to exist? Never (compat alias forever) is a defensible answer; "after one stable release" is a defensible answer. "We'll figure it out" is the worst answer. Pick one.

---

## Closing

The plan is solid as a session-resume fix. It is *visionary* as the foundation for c11 becoming the system of record for agent work in the operator's environment. The gap between those two is mostly framing and a few v1 design decisions: whether the primitive is internal or public, whether the kind namespace is flat or hierarchical, whether the CLI ships full or stubbed, whether the integration contract is documented or implicit.

The single highest-impact thing the plan author could do, in my view, is **stop treating "session resume" as the goal and start treating "the conversation primitive as a c11-native first-class object" as the goal**. Same code, mostly. Different posture. The bug gets fixed *as a byproduct* of the right architecture, and the architecture compounds where the fix wouldn't.

Everything in this review is offered in service of that reframe. The bug is real and the plan fixes it. The opportunity is much larger than the bug.
