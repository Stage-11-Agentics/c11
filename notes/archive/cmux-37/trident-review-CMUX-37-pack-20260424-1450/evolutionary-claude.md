## Evolutionary Code Review
- **Date:** 2026-04-24T14:50:00Z
- **Model:** Claude (claude-opus-4-7)
- **Branch:** cmux-37/phase-1-snapshots-restore
- **Latest Commit:** 2047daff (CMUX-37 Phase 1: acceptance fixture + skill docs)
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary/Exploratory

---

## What's Really Being Built

The stated feature is "snapshot + restore + Claude resume." That undersells it. What this branch actually ships is the **third citizen of a `WorkspaceApplyPlan` ecosystem**:

| Source                       | Producer                     | When it's authored | What's lossy        |
| ---------------------------- | ---------------------------- | ------------------ | ------------------- |
| Phase 0 debug CLI            | operator typing JSON         | now                | n/a                 |
| Phase 2 Blueprint            | hand-authored `.json` / DSL  | ahead of time      | by design (template)|
| **Phase 1 Snapshot** (this)  | `LiveWorkspaceSnapshotSource`| at capture time    | scoped (no scrollback yet) |

The branch quietly establishes that **`WorkspaceApplyPlan` is the ABI for "what is a workspace?"** Capture, restore, blueprint authoring, and the debug-CLI all funnel through one value type. Anything that can be expressed as a plan is now a candidate for: snapshot/restore, version control, agent-authored composition, distribution, and time-travel.

Even more strategically: this branch normalises the `Source -> Plan -> Executor` pipeline as the **only** way to materialize a workspace. The `LiveWorkspaceSnapshotSource` walker is the first concrete `WorkspaceSource` in everything but name. Once a second one exists (e.g., a `BlueprintFileSource` or `RemoteWorkspaceSource`), the protocol crystallises and the architecture pivots from "snapshot is a feature" to **"workspaces are content; the executor is the engine; sources are the input"** — that's a much bigger story than session resume.

The other thing being quietly created is the **agent restart contract**. `AgentRestartRegistry` looks like a single-row lookup table today, but it's actually a **late-binding seam between captured agent identity and its resurrection ritual** that:
- Doesn't ship in the wire format (so Phase 5 rows don't break old snapshots).
- Reads only from the captured surface metadata blob (so any agent that learns to set `terminal_type` + a session-id-shaped key earns "resumable" status for free).
- Returns a string command (so the implementation surface is "what shell incantation revives me?", which every agent already understands).

That contract is a fork in the road. Today it produces shell strings. The natural next mutation is for it to return **richer restart specs** (env vars, working dir overrides, structured handoffs to remote agents). Once it does, the registry is no longer about "session resume" — it's the **agent rehydration protocol** for the c11 ecosystem.

---

## Emerging Patterns

### Patterns to formalise

1. **Pure converter sandwich.** `WorkspaceSnapshotConverter` is `Foundation`-only by deliberate constraint, with the file-top comment as enforcement-by-convention. This pattern (pure conversion seam between an on-disk envelope and an executor input) is going to recur for every `Source` we add. **Formalise it as a project rule:** "every plan source ships a `Foundation`-only converter file with a `Linux-portable` header comment; tests for that converter import nothing else." That gives Phase 5/Phase 6 a tight template.

2. **Named registry → wire-string bridge.** `AgentRestartRegistry.named("phase1")` is a stunningly small piece of code that does a lot — it lets the wire format carry an opaque registry name while the *implementation* of that name evolves in-process. This pattern (named registry resolved at the receiving end) belongs everywhere we'd otherwise be tempted to serialise function tables: theme registries, mailbox routing tables, key-binding registries. **Name the pattern in the codebase** — call it the "named-registry bridge" — and reuse it.

3. **`@MainActor` capture / nonisolated convert / off-main store.** The triplet (`LiveWorkspaceSnapshotSource @MainActor`, `WorkspaceSnapshotConverter nonisolated`, `WorkspaceSnapshotStore` off-main + `Sendable`) is a clean isolation cascade. This is the right mental model for any future "snapshot a live thing" feature. Document it once, point to it forever.

4. **Origin enum on the envelope, not the plan.** `WorkspaceSnapshotFile.Origin` (manual / autoRestart) lives on the envelope — not on the plan — because the plan is shared with Blueprints, which have no concept of "auto-restart." This **Envelope-vs-Plan separation of concerns** is exactly right and should be the rule for every future "this is metadata about this snapshot, not about this workspace" question. (Today: capture timestamp, version, origin. Tomorrow: capture host, capture user, capture machine, capture causal predecessor.)

### Anti-patterns to catch early

1. **Walker-as-struct-with-mutating-methods is going to get noisy.** `LiveWorkspaceSnapshotSource.Walker` already carries surface accumulator + id counter + workspace ref. As capture grows (browser history? markdown scrollback? PTY scrollback?) the walker will need more state. Today it's still readable. By Phase 4 it'll need an explicit `CaptureContext` value passed through the recursion, with the walker being a stateless visitor over it. **Refactor before it gets big.**

2. **Stringly-typed registry-resolved-by-name has no validation in the converter.** Today an unknown registry name silently falls through to "no registry" (Phase 0 behavior). That's correct *now* (forward-compat) but it means a typo in a script (`restart_registry: "phase01"`) is a silent footgun. Add a debug-build assertion or a `warnings.append("unknown restart registry name: \(name)")` in the executor when `params["restart_registry"]` was non-nil but `AgentRestartRegistry.named(...)` returned nil. Visible-but-non-fatal is the right register here.

3. **The `claudeSessionId` literal in CLI is a duplicated source of truth.** `CLI/c11.swift:12639` hard-codes `"claude.session_id"` because the CLI target doesn't link `Sources/WorkspaceMetadataKeys.swift`. The header comment acknowledges this. **Catch it now**: extract `WorkspaceMetadataKeys.swift` into a shared module both targets can import (or codegen the literal from one source). When Phase 5 adds `codex.session_id` / `kimi.session_id`, having the literals diverge across CLI vs app is a class of bug we don't want to invite.

4. **`#if DEBUG TerminalSurface.pendingInitialInputForTests` is the wrong shape long-term.** The acceptance test peeks into `pendingTextQueue` through a debug-only accessor on the surface. That works for one test today, but every future executor harness will want this same data, and `#if DEBUG` accessors don't compose. Better shape: introduce a `TerminalInputProbe` protocol (or a thin `TerminalSurfaceTestSeam`) that ships in non-debug too but is internal/SPI-only. Pay it back when the second test wants the same hook.

---

## How This Could Evolve

### 1. Snapshots get a content-addressable layer

Today `<ulid>.json` lives in `~/.c11-snapshots/`. The id is **time-keyed** (ULID prefix is a millis-since-epoch). If you also computed a **content hash** of the embedded plan and stored it alongside, you'd unlock:

- **Dedupe.** Two captures of the same workspace with no changes are byte-identical → one file.
- **"What changed since this snapshot?"** Diff plans by content-hash to surface drift.
- **Branchable snapshots.** Once snapshots have content-hashes, they form a DAG: each capture can carry a `parent_hash` and you've built a workspace-state git, automatically.

Concrete mutation: extend `WorkspaceSnapshotFile` with `parent_snapshot_id: String?` and `content_hash: String?`. Don't *enforce* the DAG yet — just record it. The flywheel below feeds on this.

### 2. `WorkspaceSnapshotSource` becomes the protocol

Today the protocol is defined and has one production conformer (`LiveWorkspaceSnapshotSource`) plus one fake. The natural next conformers:

- **`BlueprintFileSource`** — reads a YAML/JSON blueprint into the same envelope shape (with `origin: blueprint`).
- **`RemoteWorkspaceSnapshotSource`** — fetches a snapshot from a c11 instance running on another machine via the socket.
- **`MergedSnapshotSource`** — composes two snapshots into one workspace (e.g., "this layout from machine A, this metadata from machine B").

Once the second non-test conformer exists, **the whole architecture pivots**: c11 stops being "a multiplexer with a snapshot feature" and becomes "a workspace runtime whose inputs are pluggable." That's a much more powerful framing for the operator and for the agent ecosystem.

### 3. Restart registry becomes a richer contract

`AgentRestartRegistry.Row.resolve` returns `String?`. Phase 5 will add codex / opencode / kimi — fine. But the **shape** of "rehydrate this agent" is bigger than "what shell command runs":

```swift
struct AgentRestartSpec {
    var command: String
    var workingDirectory: String?
    var environment: [String: String]?
    var preInputBytes: Data?     // e.g., a /resume command typed before the user
    var notes: String?           // e.g., "this resume requires the agent's transcript_path env"
}
```

Mutation: change `resolve` to return `AgentRestartSpec?`, with a default `AgentRestartSpec(command: ...)` initialiser so today's callers don't change. Now the registry can carry richer ritual without re-architecting.

### 4. Snapshots get a "live mirror" mode

Today snapshots are point-in-time. The natural mutation: a **streaming snapshot** that emits envelope deltas on every state change (split, metadata write, command). Persist the deltas; coalesce into full envelopes periodically. You've now built **workspace event sourcing**. Restore becomes "replay from the last full envelope + apply deltas." A crash (process or machine) costs you milliseconds of state, not the whole session.

The seam already exists: `SurfaceMetadataStore`, `PaneMetadataStore`, and `TabManager` are the three sources of truth that the walker reads from. Add a thin `WorkspaceSnapshotJournal` that subscribes to mutations on those three and appends to `~/.c11-snapshots/<ulid>.journal` — that's your delta log.

### 5. Cross-machine portability via snapshot URLs

Once snapshots are content-addressed and have a stable wire format, **make the URL the primary handle**:

```
c11 restore https://snapshots.stage11.ai/abc123
c11 restore s3://my-team/workspace-snapshots/feature-foo
c11 restore git://my-repo.git#snapshots/feature-foo
```

`WorkspaceSnapshotStore` already abstracts read/write. Add a `WorkspaceSnapshotProvider` protocol with `read(id: String) -> WorkspaceSnapshotFile`. Local file is one provider; HTTPS, S3, git, and a c11-to-c11 socket fetch are others. The agent ecosystem just got **shareable workspaces**.

### 6. The executor learns to **restart in place**

Today restore creates a brand new workspace. The next mutation: **adopt mode**. Given a live workspace and a snapshot of *what it should look like*, compute the diff and apply it. This is what `applyToExistingWorkspace` was teasing in the WorkspaceLayoutExecutor doc comment. With a diff engine, you can:

- Hot-reload a snapshot into the current workspace (split-shape preserved where possible).
- Drive the workspace from version-controlled snapshots in a project (à la `lattice dashboard`'s expected layout).
- Run **continuous reconciliation** — the operator's local workspace converges to a remote authoritative spec.

That's effectively GitOps for workspaces. The executor + plan are 80% of the way there.

---

## Mutations and Wild Ideas

### M1. **Snapshot lineage as a first-class graph**
Today: each snapshot has an id and a created_at. Add `parent_snapshot_id` (single parent: linear) or `parent_snapshot_ids: [String]` (multiple: merge). `c11 list-snapshots --tree` shows you the DAG. `c11 diff <id1> <id2>` shows you what changed. `c11 restore --from <a> --replay-onto <b>` performs a workspace rebase. This is **git for workspaces**, and the bones already exist.

### M2. **`c11 snapshot --on-event`**
Mutation: capture not on operator command but on **trigger**. `--on-event surface-close` captures right before a surface is closed (so you can restore "the workspace as it was 10 seconds ago"). `--on-event idle` captures every time the workspace goes idle for N minutes. `--on-event mailbox-receive` captures when a specific mailbox event fires. With the journal from §4, this becomes cheap. With the DAG from M1, it becomes time-travel.

### M3. **Snapshot bisect**
With M1 in place: `c11 snapshot bisect <oldest-known-good> <newest-known-bad> "test_command"`. Walks the DAG, restores each candidate snapshot, runs the test, narrows to the snapshot where things broke. The same mental model as `git bisect`, applied to workspace state. Useful when an operator's setup mysteriously stops working — *which* of the last 30 snapshots first showed the bug?

### M4. **Distributed workspace handoff**
Operator on Machine A: `c11 snapshot --share`. Returns a URL pointing at a c11 socket exposed via tunnel (or a content-addressed blob in s3). Operator on Machine B: `c11 restore <url>`. The agents in the workspace come back, with their session ids intact, ready to keep working from the same place. **The agent's identity travels with the snapshot.**

For Claude-Code specifically: `cc --resume <id>` already restores the conversation transcript. So a CMUX-37 snapshot taken on Machine A and restored on Machine B will literally hand off Claude's context across the wire — assuming Anthropic's session storage is reachable from B (true). **Cross-machine agent migration becomes a one-line operator move.**

### M5. **Workspace snapshots as Lattice artifacts**
Lattice already tracks tasks. Bind: every `c11 snapshot` taken from a workspace whose pane metadata declares `lattice.task_id` automatically files the snapshot as an artifact on that task. When a sibling agent picks up the task, `lattice show <task>` lists the snapshot links; one click restores the originating workspace state. **Workspace state becomes the universal "show me what they were doing"** — and Lattice doesn't have to invent a new artifact type, because the snapshot file IS the artifact.

### M6. **Snapshot driven by Mycelium / agent intent**
A higher-up agent (Lattice planner, Mycelium router) can **author a Blueprint** — but right now Blueprints are static. Mutation: the agent **emits a Plan**, the Plan goes through the executor, and the resulting workspace gets snapshotted. The snapshot is now the agent's *fingerprint* of the workspace it asked for — replayable, diffable, distributable. The Plan-as-data becomes the contract between the intelligence layer and the runtime layer. (This is the big one. It collapses the gap between "agent decides what should be" and "workspace is.")

### M7. **`c11 restore --as-overlay`**
What if restore didn't replace the workspace but **layered on top of it**? Restore the snapshot's surface metadata, mailbox state, and titles into a new ephemeral workspace ID — but keep pointers to the *original* live panels. You can now run two snapshots side-by-side as overlays, watching how the same panes evolve under different metadata regimes. Useful for comparing two Claude-Code sessions playing out in parallel, or for "replay this snapshot's metadata against the current panes to see if the mailbox routing was right."

### M8. **`AgentRestartRegistry` becomes the orchestration vocabulary**
Today the registry produces one shell command per agent. The mutation: **chain restarts**. A registry row could declare dependencies (`watcher restarts after driver`), parallelism (`fan out three reviewers from this one transcript`), or fanout (`every surface with terminal_type=opencode resumes against the same upstream task`). The registry stops being "how do I restart this agent?" and becomes "how does this swarm of agents come back to life?" — a small DSL for choreographing rehydration.

---

## Leverage Points

### L1. Make `WorkspaceApplyPlan` round-trippable through a hash, today
**Cost:** ~30 lines. Add `extension WorkspaceApplyPlan { var contentHash: String { /* SHA256 of canonical encoding */ } }`. **Payoff:** unlocks dedupe (§1), DAG (M1), bisect (M3), GitOps reconciliation (§6), and the test suite gains a free property: "captured plan == read-back plan" already holds; now you can *prove* it cheaply without comparing the entire structure. This is the single highest-leverage change in the next phase.

### L2. Promote `WorkspaceSnapshotSource` to a fully public protocol
**Cost:** mostly access-level changes, plus moving the protocol into `WorkspaceApplyPlan.swift` (or a new `WorkspaceSource.swift`). **Payoff:** Phase 2 Blueprints land as another `WorkspaceSource` conformer rather than a parallel parser path. The acceptance harness for *every future source* gets the same testing shape. Big architectural win for tiny code cost.

### L3. Pull snapshot key literals into a shared module
**Cost:** small refactor, modulemap or framework boundary work. **Payoff:** kills the duplication anti-pattern flagged above (CLI vs app sharing literals like `claude.session_id`). Phase 5 (codex/opencode/kimi) gets to add ONE entry per agent instead of TWO.

### L4. `restart_registry` deprecation lane in the wire format
**Cost:** 5 lines + a migration doc note. **Payoff:** today the wire carries `"phase1"` as the only registry name, but you'll want to retire that name in Phase 5 (`"phase5"`?  `"v1"`? something kind-er?). Build the deprecation aliasing now (`AgentRestartRegistry.named("phase1") == AgentRestartRegistry.named("v1")`) so future renames don't bump the wire format.

### L5. Test fixture as a generation seed
The fixture set (`mixed-claude-mailbox.json`, `claude-code-with-session.json`, etc.) is *already* a tiny corpus of "interesting workspace shapes." **Leverage point:** make these the seed for a property-based test that fuzzes plans through the executor. With a content hash (L1), you can assert that **fuzzed-plan → executor → captured → converter → executor** is a fixed point. That's a rock-solid invariant for the whole `Plan` ABI.

---

## The Flywheel

There is a real flywheel hiding in this branch, and the team should set it spinning deliberately. The loop:

1. **Capture is cheap and high-fidelity** → operators snapshot more often.
2. **More snapshots** → more proof points for fidelity, more demand for browse/search.
3. **Browse/search demand** → list / index / DAG views (M1) get built.
4. **DAG views** → operators start *navigating* between snapshots, not just restoring the most recent.
5. **Navigation** → restore-to-arbitrary-point becomes the default, and `c11 restore` becomes the *primary* way operators move between contexts. 
6. **Restore-as-default** → snapshot capture becomes part of every session-end ritual (manual or automated), feeding step 1.

The unlock that starts the loop spinning: **make `c11 list-snapshots` so good that operators discover new use cases for it.** Sort orders, filters by metadata (`--workspace-title`, `--tag`, `--age 7d`), preview ("restore --dry-run prints the plan structure"). Today it's a flat newest-first table; that's the right MVP, and now you make it a navigable surface.

A second engineerable flywheel: **the agent-restart contract creates a positive externality for any agent that adopts c11 metadata conventions.** Today that's just Claude Code via `terminal_type=claude-code`. The moment a second agent (say, codex via Phase 5) adopts the same metadata shape, the restart registry's *value* doubles for free. Document this — make it obvious that adopting `terminal_type` + `<agent>.session_id` earns you "snapshot/restorable" status with no other work. That's a compelling pitch for any agent author considering c11 integration.

---

## Concrete Suggestions

### High Value (do now / in the next phase)

1. **Add `contentHash: String` to `WorkspaceApplyPlan` (or `WorkspaceSnapshotFile`).**
   File: `Sources/WorkspaceApplyPlan.swift` or new `Sources/WorkspaceApplyPlanHashing.swift`.
   Implementation: serialise via `JSONEncoder` with `.sortedKeys`, SHA256 the bytes, hex-encode. ~30 LOC. Ships before any DAG / bisect / dedupe work needs it.
   ✅ Confirmed — `WorkspaceApplyPlan` is `Codable` and `Equatable`, and `WorkspaceSnapshotStore.write` already uses `.sortedKeys` for canonical encoding (`Sources/WorkspaceSnapshotStore.swift:103`); the hash function reuses that exact pipeline. No architectural risk.

2. **Pull `WorkspaceMetadataKeys.swift` into a target both `c11` and `c11-CLI` link.**
   Today: `Sources/WorkspaceMetadataKeys.swift` is app-only; `CLI/c11.swift:12639` hard-codes `"claude.session_id"` with a "kept in lockstep by reader convention" header. That convention is a class of bug we don't have to ship. Either make it a separate framework / SPM module, or codegen the literal from a single source.
   ✅ Confirmed — the literal is duplicated at `CLI/c11.swift:12639` (`metadata: [String: Any] = ["claude.session_id": ...]`) and at `Sources/WorkspaceMetadataKeys.swift:29` (`SurfaceMetadataKeyName.claudeSessionId`). Extracting them is mechanical; the only choice is "where does the shared module live."

3. **Add a debug-build warning when `params["restart_registry"]` has a value but `AgentRestartRegistry.named` returns nil.**
   File: `Sources/TerminalController.swift` v2SnapshotRestore (~line 4570).
   Today the typo silently falls through to Phase 0 behavior; the operator gets a fresh shell instead of a resumed one with no diagnostic. Add a `warnings.append("...")` (and surface it through `ApplyResult.warnings`) when the name was non-empty but unknown.
   ✅ Confirmed — the swallow happens at `Sources/TerminalController.swift` (v2SnapshotRestore handler, params["restart_registry"] block). Adding a warning is non-breaking; the executor already has a warnings vector for this exact purpose.

4. **Promote `pendingInitialInputForTests` to an internal SPI seam, not `#if DEBUG`.**
   File: `Sources/GhosttyTerminalView.swift:2594-2604`.
   The accessor is the right idea (don't expose `pendingTextQueue` mutable); the wrapping is wrong. `#if DEBUG` makes it invisible to release-build test targets and unavailable to any non-XCTest harness (e.g., a future CLI smoke-test). Make it `internal` (or `package`) without the `#if`. Keep the comment that says "test-only consumers."
   ❓ Needs exploration — the `#if DEBUG` guard exists to keep size down on release builds; verify this *actually* matters here (the accessor is 5 lines, no allocations). If size is genuinely a constraint, the alternative is a separate `c11-TestSupport` module that vends the seam.

### Strategic (sets up future advantages)

5. **Formalise the `WorkspaceSnapshotSource` protocol as the source-of-truth boundary.**
   Today it's a tight @MainActor protocol with a single production conformer. As Blueprints, RemoteWorkspaceSource, and MergedSource come online, the protocol's *shape* becomes load-bearing for the whole pipeline. Move it to its own file (`Sources/WorkspaceSource.swift`), document the @MainActor / nonisolated split, and write the test-fake convention down so every new conformer ships its own fake the same way.
   ✅ Confirmed — already exists as a protocol at `Sources/WorkspaceSnapshotCapture.swift:13`; the work is mostly elevation/documentation, not invention.

6. **Introduce `AgentRestartSpec` as the registry's return type (with a back-compat init from `String`).**
   File: `Sources/AgentRestartRegistry.swift`.
   Change `Row.resolve` to return `AgentRestartSpec?`; add `init(stringLiteral:)` so today's `"cc --resume \(id)"` works unchanged. New rows can declare env, cwd, pre-input bytes. The Phase 5 codex/opencode/kimi rows almost certainly want at least env vars (e.g., `OPENAI_API_KEY` swap).
   ✅ Confirmed — `AgentRestartRegistry.swift` is small enough that this is a contained change. No callers outside this branch.

7. **Build a `c11 list-snapshots --tree` view that groups by `workspace_title`.**
   File: `CLI/c11.swift` runListSnapshots (~line 2814).
   The flywheel section above turns on operators *navigating* the snapshot graph. Today's flat newest-first table is the MVP; the next leverage step is grouping. `--tree` (group by workspace_title), `--workspace <title>` (filter), `--since <duration>` (filter by age) all unlock browsing as a primary use case.
   ✅ Confirmed — `WorkspaceSnapshotIndex` already carries `workspaceTitle` and `createdAt`; this is presentation-only work over the existing data.

8. **Document the "named-registry bridge" pattern in the Lineage / DECISIONS.md log.**
   The pattern `AgentRestartRegistry.named("phase1") -> .phase1` is going to recur. Theme switcher does it. Mailbox routing will. Naming the pattern (and showing its three properties: forward-compat wire shape, app-side resolution, opaque to the file format) will save the next architect a discovery cycle.
   ✅ Confirmed — pure documentation, zero code risk.

### Experimental (worth exploring, uncertain payoff)

9. **Prototype `WorkspaceSnapshotJournal`: a delta log that subscribes to `SurfaceMetadataStore` / `PaneMetadataStore` / `TabManager` mutations.**
   Big idea — workspace event sourcing. Persist deltas to `~/.c11-snapshots/<ulid>.journal`; periodically coalesce to a fresh envelope. Restore becomes "load envelope + apply deltas." This is the path to "5-second-RPO workspaces" and recovery from a crash without losing any state. ❓ Needs a bigger spike before commitment — the metadata stores would need to expose change-event streams, which they don't today.

10. **Explore content-addressed snapshot URLs end-to-end.**
    `c11 restore https://...`, `c11 restore s3://...`, `c11 restore c11://machine-b:7878/snapshots/<id>`. The provider abstraction is small; the operator value (cross-machine handoff, shareable templates, team-wide blueprints) is large. ❓ Worth a 1-day prototype to find the friction.

11. **`c11 snapshot --on-event` capture triggers.**
    Auto-capture on surface-close, on workspace idle, on mailbox-receive. Cheap once the journal exists; without the journal, every trigger is a full envelope write — fine for low-frequency triggers (idle), wasteful for high-frequency ones (every mailbox event). Probably wait for §9 first.

12. **Workspace state diffing: `c11 snapshot diff <id1> <id2>`.**
    Plan-to-plan diff at the structural level (split shape changed; surface added; metadata key changed). Not git-diff-style; more like "two PaneSpecs have different surfaceIds." Pairs with content hashes and the DAG. Mostly a tooling exercise once the underlying data exists.

13. **Lattice integration: auto-file snapshots as task artifacts.**
    Listen for `lattice.task_id` in workspace metadata; on `c11 snapshot`, post the snapshot file to the Lattice task as an artifact. Cheap end-to-end (file copy + API call). High operator value (instant "what was the team doing on this task" replay). Could be either a Lattice-side feature consuming a c11 hook, or a c11-side hook consuming a Lattice destination.

---

## Closing Thought

The most exciting thing about Phase 1 is what the seven commits **don't say** out loud: this team is not building "snapshot/restore." They're building the **workspace runtime** — a small clean ABI (`WorkspaceApplyPlan`), an executor that doesn't care where the plan came from, a registry pattern for late-bound agent identity, and an isolation cascade that already maps to the right concurrency story.

If the next two phases keep that quiet discipline — every new feature is "another `Source`, another row in the registry, another envelope field" rather than "another carve-out" — then by Phase 5 c11 will have the cleanest workspace primitive on any platform, and the snapshot file will quietly become the lingua franca for "what is a workspace" across machines, agents, and time.

The most important investment in the next phase is **the content hash on the plan** (Suggestion 1). It's 30 lines of code that compounds into half the wild ideas in this review. Do that one, and the rest start writing themselves.
