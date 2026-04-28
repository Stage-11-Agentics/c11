# Evolutionary Review: Conversation Store Architecture

PLAN_ID=conversation-store-architecture  
MODEL=Codex  
Review type: Evolutionary

## Executive Summary

The biggest opportunity is to stop thinking of this as "session resume" and start treating it as c11's first durable work-continuation substrate. The proposed `Conversation` primitive is not just a fix for Claude/Codex restore. It is the first time c11 can remember agent work independently of a live terminal process, a pane layout, or a specific TUI's lifecycle quirks.

That is a strategic shift. Today c11 hosts agent processes. With this architecture, c11 begins hosting agent continuity.

The plan is directionally strong because it moves the durable pointer out of `surface.metadata`, makes per-TUI behavior explicit in strategies, and gives wrapper-claim / hook-push / disk-scrape signals a coherent reconciliation model. The evolutionary move I would make is to name and exploit the new layer more deliberately: make `ConversationStore` a small, boring v1 persistence core, but design the surrounding APIs as the future "work memory" rail for local agents, cloud agents, workspace recovery, handoffs, and eventually Mycelium/Lattice-adjacent orchestration.

The main improvement is sequencing: ship the minimal local resume core first, but add observability and a strategy test harness earlier than the plan implies. If the strategy layer becomes a black box, this system will be hard to trust. If it becomes inspectable, replayable, and fixture-driven, every future TUI integration gets cheaper.

## What's Really Being Built

This plan is building a durable identity layer for agent work.

The surface-level deliverable is "restore the right Claude/Codex session after c11 restarts." The underlying capability is more important:

- c11 can assign continuity to work even when the process dies.
- c11 can decouple "where the agent ran" from "what conversation should continue."
- c11 can learn from multiple weak signals instead of betting on one hook.
- c11 can preserve enough provenance to explain why it resumed something.
- c11 can eventually move conversations between surfaces, workspaces, machines, or execution backends.

That makes `ConversationRef` closer to a work-continuation capability token than a session id. The id is opaque, but the tuple `(kind, id, state, payload, provenance)` gives c11 a stable handle for "this agent thread of work can be continued somehow."

The right mental model may be:

```text
Surface = current place
Process = current body
Conversation = durable thread of work
Strategy = adapter from durable thread to a specific runtime
```

If this lands cleanly, c11 can evolve from restoring panes to restoring the operator's active field of work.

## How It Could Be Better

### 1. Promote provenance from debug field to first-class trust model

The plan records `capturedVia`, but the system will need more than a single enum as soon as multiple signals disagree. Instead of just storing the winning source, store a compact last-observed signal ledger in `payload` or a sidecar:

```swift
struct ConversationSignal: Codable, Sendable {
    let source: CaptureSource
    let observedAt: Date
    let id: String?
    let confidence: Double
    let reason: String
}
```

v1 does not need a full event log, but it should retain enough to answer: "Why did this pane resume Codex session A instead of B?" That question will come up immediately because the motivating bug is a wrong-session restore.

Minimum version: `ConversationRef` could carry `capturedVia`, `capturedAt`, and `diagnosticReason`. For Codex, examples might be:

- `matched cwd + mtime after claim`
- `matched cwd + newest activity`
- `placeholder only; no session file found`
- `ambiguous: 3 candidates; chose newest`

This makes the operator-facing `c11 conversation get --json` valuable from day one.

### 2. Split "active mapping" from "conversation catalog" conceptually

The plan says workspace snapshots are the source of truth and the global index is derived. That is correct for v1, but it would be cleaner to explicitly model two concepts:

- `SurfaceConversationBinding`: this surface should resume this conversation.
- `ConversationRecord`: c11 knows this conversation exists.

In v1 these can be serialized together under `surface_conversations`, but the conceptual split matters because future features use them differently. A surface binding is layout/workspace state. A conversation record is durable work memory. History UI, "resume into new pane," cloud strategies, and Lattice handoffs all want the latter without requiring the original surface to still exist.

If the implementation keeps one on-disk shape, the naming should still preserve the distinction internally. That avoids painting v2 into a corner where deleting a workspace accidentally means deleting all knowledge of a conversation.

### 3. Make strategy output explainable, not just executable

`ResumeAction` is currently an execution instruction. Add a thin wrapper:

```swift
struct ResumePlan: Sendable {
    let action: ResumeAction
    let confidence: Double
    let reason: String
    let warnings: [String]
}
```

Strategies should return a plan, not a bare action. The executor can still only execute `action`, but `reason` and `warnings` become the observability channel. This pays off for:

- unknown strategies
- placeholder refs
- Codex ambiguous file matches
- fresh-launch-only Opencode/Kimi
- cloud strategies that require auth
- "skip because tombstoned" cases

This also makes tests better. Tests can assert the strategy chose the right action and explainable reason, not just that it produced a command string.

### 4. Treat Codex as the forcing function for an activity model

The Codex strategy is the hard case because it lacks a start hook and the current wrapper can only mark terminal type. The plan's filter uses cwd, claim time, and surface last activity timestamp. That implies c11 needs a trustworthy per-surface activity clock.

Make that explicit as a primitive: `SurfaceActivity`.

At minimum, define what counts:

- user/agent input sent to terminal
- terminal output observed
- wrapper claim timestamp
- current cwd at launch/restore
- maybe process start time

If the activity timestamp is vague, Codex matching will be vague. If c11 gets this right, it becomes useful far beyond Codex: stale pane detection, agent health, workspace summaries, and "what changed since I looked away?"

### 5. Defer `replayPTY`

`ResumeAction.replayPTY` feels like a future capability that does not belong in the v1 action enum unless a v1 strategy emits it. Replaying scrollback is materially different from resuming a conversation: it mutates terminal presentation, not agent continuity. It has ordering and trust questions. Was the scrollback already restored by session persistence? Is it synthetic? Does the shell know about it?

I would ship v1 with:

```swift
case typeCommand(text: String, submitWithReturn: Bool)
case launchProcess(argv: [String], env: [String: String])
case composite([ResumeAction])
case skip(reason: String)
```

Add `replayPTY` later when there is a concrete consumer and a UI/debug story.

### 6. Push the c11 skill update into the implementation definition

The plan touches CLI surface, socket semantics, wrapper behavior, and agent mental model. In this repo, the c11 skill is the contract agents actually read. The implementation should not be considered complete until `skills/c11/SKILL.md` documents:

- `c11 conversation get/list/clear`
- no focused-surface fallback for conversation commands
- how agents should inspect conversation state before debugging resume
- what wrapper-claim means
- what not to do with tenant config

This is not documentation polish. It is part of making future agents use the new primitive correctly.

## Mutations and Wild Ideas

### Mutation A: Conversation Timeline

Today the plan stores the current active ref. A small extension turns it into a timeline:

```text
claim -> hook push -> scrape refresh -> suspended -> resume attempted -> alive
```

This could power `c11 conversation trace --surface <id>`, giving operators and reviewers a concise explanation of every lifecycle edge. It would be especially useful for crash recovery and wrong-session diagnosis. The timeline does not need to be large; a ring buffer of the last 20 events per conversation would be enough.

### Mutation B: Handoff Capsules

Once a conversation is a c11-owned continuation token, c11 can export a "handoff capsule":

```json
{
  "conversation": { "kind": "codex", "id": "...", "payload": {...} },
  "surface": { "cwd": "...", "title": "...", "description": "...", "role": "reviewer" },
  "workspace": { "gitBranch": "...", "snapshotId": "..." }
}
```

This is not full portability yet. It is an explicit artifact that says: "Here is enough context to continue this work elsewhere." That aligns with the operator:agent pair mission and could feed Lattice, Mycelium, or a future cloud agent bridge.

### Mutation C: Conversation Forks

If history exists, forking becomes natural. A future command could resume a prior conversation into a new pane while keeping the original pane untouched:

```bash
c11 conversation fork --id <conversation-ref> --workspace current --direction right
```

This is powerful for review workflows: one agent continues implementation, another resumes the same context to critique or test. It also matches how operators already run many agents in parallel.

Do not ship this now, but avoid naming and schema choices that make it awkward.

### Mutation D: Strategy Fixture Lab

Create a small local harness where a strategy can be fed fixture directories and surface signals:

```bash
c11-dev conversation-strategy test codex fixtures/codex/two-panes-same-cwd.json
```

This is not a user feature. It is a compounding development tool. Every new TUI integration starts by collecting a few session-storage fixtures and writing a strategy test. That would turn "reverse engineer Opencode/Kimi" from artisanal debugging into a repeatable integration workflow.

### Mutation E: Work Continuity Score

Expose a per-surface "resume confidence" score in debug output:

```json
{
  "state": "suspended",
  "resume_confidence": 0.82,
  "reason": "codex session matched cwd, claim time, and post-claim mtime"
}
```

The UI does not need to show this in v1, but the CLI should. The operator can immediately distinguish "this will resume exactly" from "this is best-effort fresh launch."

## What It Unlocks

1. **Correct same-cwd Codex resume.** This is the immediate unlock: `codex resume <specific-id>` replaces `codex resume --last`.

2. **Crash-aware restore.** The `unknown -> scrape -> suspended/tombstoned` path makes power loss and `kill -9` recoverable in a way wrapper-only capture cannot.

3. **A unified integration story for weak TUIs.** Opencode and Kimi can begin as fresh-launch strategies and evolve toward scrape support without changing snapshot schema or wrapper philosophy.

4. **Conversation observability.** `c11 conversation list/get` becomes the diagnostic doorway for "what will this pane resume and why?"

5. **Future history UI.** The `history` field is a small schema bet that unlocks "previous conversations" without revisiting the storage model.

6. **Remote/cloud strategy path.** `kind` + opaque `id` can represent local files, remote URLs, cloud conversation IDs, or service-side tokens.

7. **Agent orchestration leverage.** Once c11 can enumerate durable conversations, other systems can reason about active work rather than only live terminals.

8. **Cleaner wrapper constraints.** Wrappers shrink back toward the project principle: declare kind, claim start, inject hooks only where the TUI supports them, never persist tenant config.

## Sequencing and Compounding

I would sequence this in four slices:

### Slice 1: Core store and CLI observability

Build `ConversationRef`, `SurfaceConversations`, `ConversationStore`, and `c11 conversation get/list/clear/claim/push/tombstone` first. Do not wire autoscrape yet. Make commands strict about `CMUX_SURFACE_ID`: no focused fallback.

This gives a testable substrate and lets wrappers begin writing claims.

### Slice 2: Claude strategy and tombstone semantics

Move Claude from `claude.session_id` metadata to `conversation push/tombstone`. Add the `isTerminatingApp` query or equivalent app-state gate. Preserve `claude-hook` as a translator for compatibility.

Claude is the best first strategy because it has explicit hook ids and can validate the state machine cleanly.

### Slice 3: Codex strategy and fixture harness

Implement Codex scraping only after the activity model and fixture tests are clear. This is the riskiest matching logic, so it should not be implemented as a one-off buried in the store. Make the ambiguity cases observable.

This slice should specifically reproduce the staging QA failure: two Codex panes, same cwd, distinct sessions, correct specific resume.

### Slice 4: Restore integration and crash recovery

Refactor `Workspace.scheduleAgentRestart` from command strings to `ResumePlan`/`ResumeAction`, then add clean-shutdown marker behavior and crash recovery.

Doing crash recovery last is fine if the store and strategies are already testable. Doing it too early risks mixing lifecycle policy, persistence schema, and strategy correctness in one hard-to-debug change.

### Where to do less now

- Do not persist the global derived index in v1.
- Do not implement history UI in v1.
- Do not add cloud/remote kinds in v1.
- Do not support third-party strategy plugins.
- Do not ship `replayPTY` without a concrete emitter.

### Where to invest early

- CLI observability.
- Strategy fixtures.
- Activity timestamp semantics.
- Provenance/reason strings.
- Skill documentation.

Those are small compared with UI features, but they compound every future integration.

## The Flywheel

The flywheel is:

1. c11 captures conversation refs more reliably.
2. Operators trust resume and keep more agent work inside c11.
3. More TUI kinds and edge cases run through the same store.
4. Strategy fixtures and diagnostics improve.
5. New integrations get cheaper.
6. c11 becomes the natural place to inspect and continue agent work.
7. That creates more pressure and more data to improve the store.

To accelerate the flywheel, the first shipped version must be explainable. If a wrong conversation resumes and the only answer is "strategy picked newest file," trust collapses. If `c11 conversation get --json` says exactly which signals matched and which were ambiguous, operators will tolerate v1 limitations and feed better cases back into the fixture lab.

There is a second flywheel around agent skill:

1. Skill teaches agents to inspect conversation state.
2. Agents debug their own resume/capture issues faster.
3. Fewer human interrupts.
4. More agents can run in parallel.
5. c11's value as the operator's command center increases.

That only works if the skill update lands with the implementation.

## Concrete Suggestions

1. Rename the internal conceptual layer from "session resume" to "work continuity" in comments and diagnostics where appropriate. Keep user-facing CLI as `conversation`; avoid overloading with "session" except when referring to a TUI's native session file.

2. Add `ResumePlan` around `ResumeAction` with `reason` and `warnings`. This is the smallest change that makes strategies explainable.

3. Store a compact diagnostic reason on every `ConversationRef` update. For Codex, this should include candidate count and match dimensions.

4. Make `c11 conversation get --json` useful before any UI work. It should show active ref, state, captured source, captured time, payload summary, last reason, and whether a registered strategy can resume it.

5. Define `SurfaceActivity` explicitly before Codex scraping. If "last activity timestamp" is part of the filter, it needs a documented source of truth.

6. Build strategy fixtures as part of the first implementation PR, especially for Codex same-cwd ambiguity. Avoid tests that grep source; use fixture session-storage layouts and strategy inputs.

7. Keep the global index in memory for v1, but make the builder API return both records and warnings. A corrupted snapshot should not block launch, but it should be visible in diagnostics.

8. Use actor isolation for `ConversationStore` unless there is a concrete reason not to. The plan proposes a serial dispatch queue; that works, but this is a new subsystem and a good place to align with Swift concurrency rather than adding another queue-owned mutable store.

9. Keep wrapper writes best-effort and latency-bounded, matching the current wrapper pattern. A failed claim must never block the TUI launch.

10. Do not let `CMUX_DISABLE_AGENT_RESTART=1` suppress capture by default. It should suppress automatic resume only. Capture is low-risk observability and gives the operator something to inspect even when auto-resume is disabled.

11. Add a one-release compatibility bridge that reads `claude.session_id` metadata into a `ConversationRef` on restore, then writes only the new conversation field afterward. This preserves the plan's no-migration stance while avoiding a hard cliff for pre-release snapshots.

12. Make unknown strategy behavior non-destructive: keep the ref, skip resume, and expose `strategy_status: "missing"`. Do not tombstone just because the current binary lacks the strategy.

13. Update `Resources/bin/codex` comments as part of implementation. Its current comment says `codex resume --last` is acceptable best-effort; after this plan, that comment becomes actively misleading.

14. Update `skills/c11/SKILL.md` in the same unit of work. Agents need to know the conversation commands and the no-focused-fallback rule.

15. Consider a future `c11 conversation export` handoff capsule, but do not build it now. Let the schema choices preserve that path.

## Questions for the Plan Author

1. Is the intended long-term identity "conversation", "work thread", or "continuation"? The v1 CLI can be `conversation`, but the conceptual name matters for future Lattice/Mycelium integration.

2. Should `ConversationRef` store only the winning capture source, or should it retain a small signal ledger for explainability?

3. What is the canonical source of `surface.lastActivityTimestamp`, and does it mean input, output, focus, process start, or any terminal activity?

4. For Codex same-cwd matching, what should happen when two candidate session files tie across cwd and timing? Resume newest, skip as ambiguous, or surface a warning and choose?

5. Should strategies return `ResumeAction` directly, or an explainable `ResumePlan` with confidence/reason/warnings?

6. Should unknown strategy refs be retained indefinitely as "missing strategy" instead of skipped and forgotten?

7. Is `history` intended to be per-surface history only, or the seed of a broader conversation catalog? If broader, should the code names reflect bindings vs records now?

8. Does `CMUX_DISABLE_AGENT_RESTART=1` disable only resume execution, or also wrapper claim/push capture? I recommend execution only.

9. Should the clean-shutdown marker be global, per app instance, or per snapshot generation? A global marker is simple but may be ambiguous if multiple debug-tagged c11 instances run.

10. Is there a requirement to preserve old `claude.session_id` snapshots for one release, or can pre-release users tolerate losing resume for those snapshots?

11. Should the `claude-hook` compatibility path continue writing existing telemetry breadcrumbs after it routes conversation events, or should conversation events become the new telemetry source?

12. Can the first implementation PR include the c11 skill update, or should that be a required follow-up before release qualification?

13. What is the minimal operator-facing diagnostic command that would have made the 2026-04-27 staging QA failure obvious before restart?

14. Is Opencode/Kimi fresh-launch behavior acceptable under a `ConversationRef(state: .unknown)` placeholder, or should these strategies explicitly report `skip(reason:)` until scrape support is mapped?

15. Should the future global index be keyed by conversation id alone, or by `(kind, id)`? The latter seems necessary because ids are opaque and may collide across TUI kinds.
