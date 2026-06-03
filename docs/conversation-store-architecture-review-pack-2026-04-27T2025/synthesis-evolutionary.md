# Evolutionary Review Synthesis: Conversation Store Architecture

**Plan:** `conversation-store-architecture`
**Reviewers:** Claude (Opus 4.7), Codex, Gemini
**Synthesis date:** 2026-04-27
**Review type:** Evolutionary / Exploratory

---

## Executive Summary

All three reviewers converge on a single reframe: **this is not a session-resume bug fix; it is c11 taking ownership of agent-conversation as a first-class, durable, TUI-agnostic primitive.** The plan understates what is actually being built.

- **Claude** frames it as c11 becoming "the agent-system-of-record" — a strategic claim on the conversation graph that nobody else can ship.
- **Codex** frames it as a "durable identity layer for agent work" — separating *current place* (surface), *current body* (process), and *durable thread of work* (conversation).
- **Gemini** frames it as the shift from c11 as "spatial orchestrator" to "temporal orchestrator" — a universal agent memory bus.

All three agree the bug is real and the plan fixes it, but the *primitive* the plan introduces is the prize. The single highest-leverage move is to treat the v1 *shape* (CLI surface, kind namespacing, payload schema, history field, observability) as a public contract from day one. Implementation may simplify; the shape must not.

The strongest convergent recommendations:

1. Promote the conversation primitive to a first-class CLI/socket noun on day one, not as an internal implementation detail.
2. Make strategy outputs *explainable* (reason, confidence, warnings) so trust survives the first wrong-session restore.
3. Populate `history` in v1 even before any UI consumes it — data compounds before features.
4. Promote `cwd` (and provenance/diagnostics) out of opaque `payload` and into first-class fields where universal.
5. Document the integration contract (`ConversationStrategy`) publicly as a v1 deliverable, not a v2 docs pass.
6. Update `skills/c11/SKILL.md` in the same unit of work — agents need the new verbs to use the primitive correctly.

---

## 1. Consensus Direction (What All Three Models See)

Themes that appeared in two or three reviews, ordered by strength of agreement.

1. **Reframe from "session resume" to "conversation as first-class primitive."** Unanimous. All three reviewers explicitly call out that the plan undersells itself by framing this as a bug fix. The conversation object is the strategic asset.

2. **The primitive must be queryable, addressable, and agent-facing — not internal.** Claude and Codex both push hard on exposing the conversation API via CLI/socket from day one (Claude: "agents talk to them too"; Codex: "make `c11 conversation get --json` valuable from day one"). Gemini argues the same via "expose CLI primitives early before baking opinionated UI."

3. **Populate `history` in v1.** All three explicitly call this out. The cost is trivial (append on tombstone/replace); the value compounds before any UI exists. Gemini calls it "trust leading to abandonment"; Claude calls it "options on the future."

4. **Strategy outputs must be explainable, not just executable.** Claude (open question 7 / `unsupported` state), Codex (`ResumePlan` wrapping `ResumeAction` with reason/confidence/warnings), and Gemini (provenance routing) all converge on: when a wrong session resumes, the system must be able to say *why*. Without this, trust collapses on the first failure.

5. **Promote universal payload fields (especially `cwd`) to first-class.** Codex and Gemini both call this out directly. `cwd` is universal across software-engineering agents and load-bearing for Codex matching, cross-workspace routing, and future global queries. Claude implies the same via the "reserved payload key registry" suggestion (S13).

6. **Defer or drop `replayPTY` from v1.** Claude (S5) and Codex (suggestion 5) both explicitly say cut it. It conflates terminal presentation with conversation continuity, invites scrollback-replay misuse, and has no v1 emitter.

7. **Make `ConversationStore` a Swift actor, not a serial dispatch queue.** Claude (S3) and Codex (suggestion 8) agree directly. Greenfield site for actor isolation, idiomatic Swift concurrency, cleaner test seam.

8. **The c11 skill update is part of the implementation, not a follow-up.** Claude (sequencing step 3), Codex (suggestion 14), and Gemini (implicit via "expose CLI primitives early") all treat `skills/c11/SKILL.md` as load-bearing. The primitive only earns its keep if agents read about it.

9. **Conversation forking is the natural next move.** All three name it (Claude Mutation 3, Codex Mutation C, Gemini "Conversation Forking"). The unit of *exploration* shifts from "10 panes" to "10 forks of one investigation."

10. **The integration contract (`ConversationStrategy`) is the prize, not the implementation detail.** Claude argues this most explicitly (the v1 *shape* is what lets the flywheel turn). Codex echoes via "fixture lab + how-to-write-a-strategy doc." Gemini's framing (universal memory bus) implies the same.

---

## 2. Best Concrete Suggestions (Most Actionable Across Reviewers)

Sorted by payoff-to-effort ratio. Items with multi-reviewer support are flagged.

1. **Add `ResumePlan` wrapper around `ResumeAction` with `reason`, `confidence`, `warnings`.** [Codex; Claude implies] The smallest single change that makes strategies explainable. Tests assert reason as well as action. Operators get useful `c11 conversation get --json`. Cost: one struct, one rename.

2. **Populate `history` on every `alive → tombstoned` or active-replacement transition.** [Claude, Codex, Gemini — unanimous] Cost is appending a ref to an array on state transition. UI ignores it in v1. Data compounds. Without this, the temporal advantage is lost the moment the v1 ships.

3. **Promote `cwd` from `payload` to a first-class field on `ConversationRef`.** [Codex, Gemini] Universal across software-engineering agents. Critical for Codex matching, cross-workspace routing, global queries. Doing it later is a migration; doing it now is free.

4. **Adopt namespaced kinds (`vendor/product[@version]`) at v1.** [Claude S1] Five-minute design change. Prevents future versioning migration when Claude Code 3.0 ships. Enables `user/<custom-kind>` for operator scripts and Lattice agents without retrofit.

5. **Make `ConversationStore` a Swift actor.** [Claude S3, Codex 8] Open question 11's answer is yes. Idiomatic, cleaner test seam, no future migration to actor isolation.

6. **Drop `replayPTY` from `ResumeAction` enum in v1.** [Claude S5, Codex 5] No concrete v1 emitter. Conflates presentation and continuity. Invites future misuse. Add later when there is a specific use case.

7. **Promote conversation CLI verbs (`list`, `show`, `tag`, `rename`, `watch`, `tail`) to ship in v1, even as stubs.** [Claude S2, Codex implicit, Gemini implicit] CLI is the integration contract for operators and agents. Designing it first surfaces shape problems the internal layer never would.

8. **Update `skills/c11/SKILL.md` in the same PR as implementation.** [Claude sequencing, Codex 14] Without skill update, agents won't use the primitive correctly and the flywheel doesn't turn.

9. **Build strategy fixture harness alongside Codex implementation.** [Codex Mutation D + suggestion 6, Claude question 12] Reproduce the staging QA failure (two Codex panes, same cwd, distinct sessions). Every future strategy starts by collecting fixtures and writing a test. Turns reverse-engineering Opencode/Kimi from artisanal debugging into repeatable workflow.

10. **Add `unsupported` (or `strategy_status: "missing"`) state distinct from `unknown`.** [Claude S11, Codex 12] Forward-compat insurance for snapshots written by future c11 versions with strategies the current binary lacks. Retain the ref, skip resume, surface in diagnostics. Do not tombstone.

11. **`CMUX_DISABLE_AGENT_RESTART=1` should suppress only execution, not capture.** [Codex 10] Capture is low-risk observability. Operator should always have something to inspect even when auto-resume is disabled.

12. **Encode timestamp in `shutdown_clean` flag, not just existence.** [Claude S6] One line of code. Compare to snapshot `capturedAt`; if more than ~10s apart, run crash recovery anyway. Defends against the "snapshot wrote, system slept, sleep-killed" sequence.

13. **Make pull-scrape a strategy method, not a c11 built-in.** [Claude S12] The strategy owns the file-system code. Avoids c11 baking in assumptions about how TUIs store sessions (SQLite? `~/Library/Application Support`? remote sync?).

14. **Reserve a small registry of payload keys (`cwd`, `model`, `transcriptPath`, `lastUserMessageAt`, `tokensUsed`) with strategy-specific keys under `<kind>.foo`.** [Claude S13] Two-paragraph convention prevents six months of strategy-implementation drift.

15. **Define `SurfaceActivity` explicitly before Codex scraping.** [Codex 4] If "last activity timestamp" is part of the matching filter, it needs a documented source of truth — input, output, focus, claim, process start. Useful far beyond Codex (stale pane detection, agent health, workspace summaries).

16. **Use FSEvents on hookless TUI session directories instead of 30s polling.** [Gemini] Turn the polling fallback into a near-instant push. Closes the crash-recovery gap for Codex/Opencode/Kimi without waiting for vendor hooks.

17. **Emit socket events on conversation state transitions (`alive → suspended`, etc.).** [Gemini suggestion 3, Claude S10] Sidebar telemetry, external scripts, future MCP servers can react without polling. The connective tissue Mutations like Lattice binding depend on.

18. **Add a one-release compatibility bridge that reads `claude.session_id` metadata into a `ConversationRef` on first launch.** [Codex 11] Preserves the plan's no-migration stance without a hard cliff for pre-release snapshots.

19. **Update `Resources/bin/codex` comments as part of implementation.** [Codex 13] Current comment claims `codex resume --last` is acceptable best-effort; after this plan, that comment becomes actively misleading.

20. **Ship a "how to write a Strategy" doc with v1.** [Claude S8] The integration contract is what makes "a new kind is one Swift file" a load-bearing claim instead of an aspirational one.

---

## 3. Wildest Mutations (Creative / Ambitious Ideas)

Ranked by how much they would reshape c11 if they landed. All three reviewers gestured at the same mutation space; the boldest moves are below.

1. **Conversation forking as a first-class verb.** [Claude Mutation 3, Codex Mutation C, Gemini] `c11 conversation fork <id> --in-new-pane`. Operator who's running 10 panes is really running 10 forks of one investigation. Conversations-as-DAG is the latent shape; this is the explicit move. Most ambitious because it requires the strategy to know how to *seed* a new conversation from a prior one's transcript — Claude Code supports this; Codex doesn't natively but a strategy could fake it.

2. **Conversations as a Lattice content type.** [Claude Mutation 1] `c11 conversation tag <id> --lattice <ticket-id>`. The Lattice dashboard then shows "Atin has 4 active conversations against C11-24, in workspace c11-dev, last activity 3m ago." Conversations-and-tasks-as-the-same-fabric — exactly the operator-and-agent thesis Stage 11 is building toward. Lift on c11: a single CLI verb. Lift on Lattice: a content-type definition.

3. **Conversation API exposed over MCP.** [Claude Mutation 7] Wrap the conversation socket API in MCP and expose it as a tool to agents *running inside the panes*. Now Claude inside pane A can call a tool that reads the live transcript of Codex inside pane B. Cross-agent reasoning becomes a tool call instead of a prompt-engineered shared-doc dance. Short to ship if the underlying primitive exists.

4. **Headless background conversations.** [Gemini] A "suspended" conversation doesn't strictly need to be resumed into a visible UI surface. c11 could resume long-running conversations in headless PTYs for background tasks (test fixing, massive refactors), surfacing them to a UI pane only when they need operator input or reach a terminal state. Decouples conversation lifecycle entirely from surface lifecycle.

5. **Cross-agent handoff (kind-changing).** [Gemini, Claude implies] An operator suspends an `opencode` session, extracts its context, resumes it inside a `claude-code` pane. Requires standardized payload (cwd, intent, working set). The provocative version: conversations don't belong to TUIs, they pass through them.

6. **Conversation Timeline / Trace.** [Codex Mutation A] `c11 conversation trace --surface <id>` showing every lifecycle edge: `claim → hook push → scrape refresh → suspended → resume attempted → alive`. Ring buffer of last 20 events. Powers crash recovery and wrong-session diagnosis. Cheap. High operator-confidence value.

7. **Time-travel / mid-conversation rewind.** [Claude Mutation 4] Once `history: [Ref]` exists, the building block for "rewind this conversation to its state 20 minutes ago" exists too. Most TUIs don't support mid-conversation rollback — but the *seam* (keeping a list of refs over time and resuming from any) costs nothing in v1 if you preserve the `history` field and let it grow.

8. **Conversations on the operator's iPhone.** [Claude Mutation 5] `claude-code-mobile` strategy. Operator's iPhone surfaces "your active c11 conversations" and lets you append a one-line message via voice. The mobile app isn't running the TUI; it's appending to the conversation, which c11 desktop picks up next time the workspace opens. Far-future, but a natural extension once conversations live in c11, not the TUI.

9. **Cross-workspace mobility.** [Gemini] A conversation started in Workspace A could be detached, held in the global index, and resumed in Workspace B. The conversation is now a portable entity, not a permanent resident of a single UI coordinate.

10. **Conversation diffs / git-shaped conversation log.** [Claude Mutation 6] Internally, a conversation is a sequence of deltas (user message, agent message, tool call, tool result), and `ConversationRef.id` is content-addressed by hash of the delta sequence. Branch, merge, diff, replay any prefix. Probably too ambitious for v1; possibly the right v3 direction if c11 wants to be "the system of record for agent work" rather than "yet another terminal multiplexer."

11. **Handoff Capsules.** [Codex Mutation B] `{conversation, surface, workspace}` JSON export. Not full portability — an explicit artifact that says "here is enough context to continue this work elsewhere." Feeds Lattice, Mycelium, future cloud agent bridge.

12. **Markdown surfaces as a degenerate conversation kind.** [Claude S14] `c11/markdown-pane` kind. The conversation is between the operator and the document. Stress-tests the `kind` system early. Unlocks "show me my last edited markdown surface" via the same machinery as agent resume.

---

## 4. Flywheel Opportunities

Self-reinforcing loops the reviewers identified, plus where they overlap.

### Flywheel A — The Integration Flywheel [Claude]

```
More TUI integrations land
    → primitive becomes more universal
    → higher-level features (Lattice binding, search, forking) cover more surface area
    → operator and agents adopt c11 more deeply
    → more TUI vendors / agent systems want to play well with c11
    → easier to build a strategy than to build their own multiplexer
    → (back to top)
```

**Accelerator:** The integration contract must be public and documented. The "a new kind is one Swift file" claim has to be load-bearing, not aspirational. Two strategies a year is too slow; two a month is alive. Ship the strategy doc, fixture harness, and three deliberately-varied strategies (claude with hooks, codex without hooks, one weird third one) in v1.

### Flywheel B — The Trust / Observability Flywheel [Codex]

```
First version is explainable (reason, confidence, signal ledger)
    → operator trusts resume even when it's wrong
    → operator tolerates v1 limitations
    → operator feeds better cases into the fixture lab
    → strategies get better
    → more TUI kinds and edge cases run through the same store
    → integration cost drops further
```

**Accelerator:** `c11 conversation get --json` must be useful from day one. If the only answer to "why did this resume the wrong session?" is "strategy picked newest file," trust collapses on first failure. If the answer is "matched cwd + claim time + post-claim mtime + 2 candidates rejected," trust survives.

### Flywheel C — The Skill / Agent Flywheel [Codex, Claude]

```
Skill teaches agents to inspect conversation state
    → agents debug their own resume/capture issues faster
    → fewer human interrupts
    → more agents can run in parallel
    → c11's value as the operator's command center increases
    → more pressure on the primitive to be correct
    → primitive improves
```

**Accelerator:** Skill update lands with implementation. Without it, every agent reverse-engineers the system from existing transcripts.

### Flywheel D — The Trust-Leads-to-Abandonment Flywheel [Gemini]

```
Operator trusts c11 will never lose a conversation
    → operator stops carefully managing agent lifecycles
    → operator recklessly closes panes and hits Cmd+Q
    → more conversations become suspended/tombstoned rather than cleanly resolved
    → massive implicit history of disconnected agent work accumulates
    → c11 surfaces this history as a searchable knowledge base
    → c11 becomes the most critical asset in the operator's stack
    → further usage and trust
```

**Accelerator:** Populate `history` in v1, even with no UI. Gemini's flywheel only spins if data accumulates before the operator notices. By the time v2's history-picker UI lands, there are already months of conversation refs to surface.

### Flywheel E — The Coordination Flywheel [Claude Mutations 1, 2, 7]

```
Conversations are addressable + queryable
    → agents can cite each other's conversations (Mutation 2)
    → cross-pane coordination becomes a tool call (Mutation 7 / MCP)
    → Lattice tickets bind to live conversations (Mutation 1)
    → operator-and-agent pair coordinates as a conversation graph
    → c11 differentiation from "yet another multiplexer" becomes structural
```

**Accelerator:** Socket exposure of the conversation API from day one. CLI-only forces every external tool to shell out; socket lets MCP, Lattice, and future surfaces all consume the same stream.

---

## 5. Strategic Questions for the Plan Author

Deduplicated and merged across all three reviews. Ordered roughly by "answer this first" to "answer this eventually."

1. **Is the conversation primitive intended to become a public, queryable, agent-facing object — or strictly an internal implementation detail of session resume?** [Claude 1] The plan reads as the latter; the flywheel argument says it should be the former. Answer changes scope significantly.

2. **Will the conversation store be on the c11 socket from day one, or CLI-only?** [Claude 5] Socket exposure unlocks MCP, dashboards, agent-to-agent citation. CLI-only forces every external tool to shell out.

3. **Are you willing to ship v1 with namespaced kinds (`vendor/product[@version]`)?** [Claude 3] Five-minute cost; avoided cost is a future migration. Recommended unconditionally.

4. **Should `cwd` (and `git_branch`) be first-class fields on `ConversationRef` rather than buried in `payload`?** [Gemini 1, Codex implies] Universally applicable to software-engineering agents and critical for filtering, scraping, and routing.

5. **Should strategies return `ResumeAction` directly, or an explainable `ResumePlan` with confidence/reason/warnings?** [Codex 5] Smallest change that makes the system explainable. Recommended yes.

6. **Should `ConversationRef` retain a small signal ledger for explainability, or only the winning capture source?** [Codex 2] Examples: `matched cwd + mtime after claim`, `ambiguous: 3 candidates; chose newest`. Defends trust on first wrong restore.

7. **What happens to an `alive` session when the user starts a *new* session in the same surface? Is the old ref dropped?** [Gemini 2] Critical question — the answer determines whether the temporal advantage is preserved or immediately lost.

8. **Should `history` be populated in v1 (on tombstone / replacement), or strictly empty until v2 UI ships?** [Gemini implicit, Claude implicit, Codex sequencing] Recommended: populate now.

9. **What is the canonical source of `surface.lastActivityTimestamp`? Input, output, focus, process start, or any terminal activity?** [Codex 3] If "last activity" is part of Codex matching, it needs a documented source of truth. Useful beyond Codex.

10. **For Codex same-cwd matching, what should happen when two candidate session files tie?** [Codex 4] Resume newest, skip as ambiguous, or surface a warning and choose? Determines wrong-session-rate ceiling.

11. **What is the relationship between `Conversation` and Lattice artifacts?** [Claude 2] Stage 11 has another agent-native primitive in Lattice; binding them at v1 is a small lift with large payoff. Is there a reason not to?

12. **What's the target for "number of strategies shipped in v1"?** [Claude 4] Three strategies prove the contract is real; one proves nothing. Recommended: claude (hooks), codex (no hooks), one deliberately-weird third (markdown? operator-script?).

13. **Should the conversation API be exposed over MCP at any point?** [Claude 10] Wrapping the API in MCP turns "agents inside c11 panes" into "agents that can reason about each other." Worth flagging early because the schema choices made now affect later MCP shape.

14. **What's the recovery story for "the snapshot points to a kind we don't have a strategy for"?** [Claude 7, Codex 6] Plan's open question 4 asks this. Recommended: `unsupported` state, retain ref, skip resume, auto-promote on future strategy releases. Confirm direction.

15. **Should `CMUX_DISABLE_AGENT_RESTART=1` disable only resume execution, or also wrapper claim/push capture?** [Codex 8] Recommended: execution only. Capture is low-risk observability.

16. **For hookless TUIs, could `FSEvents` on session directories trigger push-like capture rather than 30s polling?** [Gemini 3] Closes the crash-recovery gap. Compatible with the strategy-owns-scrape pattern Claude proposes.

17. **PR #94 release management: bundle or sequence?** [Claude 6] Bundling architectural rewrites with held releases stretches release windows. Sequencing means 0.44.0 ships imperfectly and 0.45.0 fixes it properly. Operator's call but worth being explicit.

18. **Is there appetite for a "user-defined strategy" path?** [Claude 8] If yes, design v1 to allow `user/<custom-kind>`; if no, document why and close that door explicitly. Indecision is the worst case.

19. **How does `c11 conversation push` authenticate that the push comes from a legitimate agent process in that surface vs. a rogue background script?** [Gemini 4] Is `CMUX_SURFACE_ID` sufficient security? Threat model deserves explicit answer.

20. **If history is populated and operator has hundreds of snapshots, will scanning for the global derived index cause noticeable launch latency?** [Gemini 5] Should the scan be asynchronous or deferred? Affects v1 startup cost.

21. **Is the operator the primary user of this primitive, or are agents?** [Claude 14] Both, obviously. But the primary changes design priorities. Agent-primary → MCP exposure and machine-readable verbs. Operator-primary → CLI ergonomics and skill doc. Plan should be explicit.

22. **What is the canonical name for the conceptual layer — "conversation," "work thread," or "continuation"?** [Codex 1] CLI can be `conversation`; the conceptual name matters for future Lattice/Mycelium integration.

23. **Is there a requirement to preserve old `claude.session_id` snapshots for one release, or can pre-release users tolerate losing resume?** [Codex 10] Determines whether a one-release compatibility bridge is needed.

24. **Should the `claude-hook` compatibility path continue writing existing telemetry breadcrumbs after routing conversation events, or should conversation events become the new telemetry source?** [Codex 11] Affects deprecation timeline.

25. **What's the deprecation story for the existing `claude-hook` CLI surface?** [Claude 15] At what point does `c11 claude-hook session-start` cease to exist? Never (compat alias forever) is defensible. "After one stable release" is defensible. "We'll figure it out" is the worst answer.

26. **What's the contract with `c11 send`?** [Claude 9] After conversations exist, "send a message to a conversation" is a more semantically rich operation than "send keystrokes to a PTY." Should `c11 conversation message <id> "..."` exist as a higher-level alternative, dispatched per-strategy? Far-future but the seam is decided here.

27. **Is the plan author committed to documenting the `ConversationStrategy` integration contract publicly as part of v1?** [Claude 11] The "a new kind is one Swift file" claim is aspirational without a public doc that says what shape the file takes, what guarantees the strategy provides, and what c11 promises in return.

28. **Should the future global index be keyed by conversation id alone, or by `(kind, id)`?** [Codex 15] Latter seems necessary because ids are opaque and may collide across TUI kinds.

29. **Is there interest in a `conversation diff` / `conversation export` primitive in v1.x?** [Claude 13, Codex Mutation B] Even if not shipped, on-disk format decisions (especially `payload` structure) determine whether this becomes possible later.

30. **What's the test fixture story for strategies?** [Claude 12, Codex Mutation D] Are fixtures checked in? Synthesised at test time? If a TUI vendor changes storage layout, do tests catch it or pass-but-fail-in-production? Shapes the cost of every future strategy.

31. **What is the minimal operator-facing diagnostic command that would have made the 2026-04-27 staging QA failure obvious before restart?** [Codex 13] A useful forcing function for v1's `c11 conversation get --json` shape.

32. **Is Opencode/Kimi fresh-launch behavior acceptable under `ConversationRef(state: .unknown)` placeholder, or should those strategies explicitly report `skip(reason:)` until scrape support is mapped?** [Codex 14] Affects honesty of the resume model.

33. **Should the clean-shutdown marker be global, per app instance, or per snapshot generation?** [Codex 9] Global is simple but ambiguous if multiple debug-tagged c11 instances run.

---

## Closing Note

The bug is real and the plan fixes it. The opportunity, all three reviewers agree, is much larger than the bug. The single highest-impact reframe is to stop treating "session resume" as the goal and start treating "the conversation primitive as a c11-native first-class object" as the goal. Same code, mostly. Different posture. The bug gets fixed *as a byproduct* of the right architecture, and the architecture compounds where the fix wouldn't.

The risk is that the v1 *shape* gets simplified during implementation review (history field omitted, payload field cut, namespace deferred, CLI shrunk to internal-only) in ways that close the doors the plan currently leaves open. The reviewer's job is to enforce that the v1 shape survives — fields are options on the future, and options are valuable even when unexercised.
