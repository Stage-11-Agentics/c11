# Evolutionary Synthesis — CMUX-37 Phase 1

- **Date:** 2026-04-24
- **Branch:** cmux-37/phase-1-snapshots-restore
- **Sources:** evolutionary-claude.md, evolutionary-codex.md, evolutionary-gemini.md
- **Review Type:** Synthesis of Evolutionary/Exploratory reviews

---

## Executive Summary — Biggest Opportunities

All three reviewers independently arrive at the same headline: **Phase 1 is not a session-resume feature. It is the birth of a workspace runtime where `WorkspaceApplyPlan` is the executable IR for "what is a workspace?"** Snapshots are merely the third citizen (after debug-CLI plans and Phase 2 Blueprints) of an emerging plan ecosystem. The strategic implication, named differently by each model, is the same:

- Claude calls it the **`Source -> Plan -> Executor` pipeline** that pivots c11 from "multiplexer with snapshots" to "workspace runtime whose inputs are pluggable."
- Codex calls it **"workspace memory as executable infrastructure"** — the IR is the substrate; transforms and registries evolve around a stable envelope.
- Gemini calls it an **"Agent State Hypervisor"** — the snapshot is the call stack for a distributed intelligence session; workspaces become detachable workloads.

The three highest-leverage near-term moves, agreed by at least two reviewers each:

1. **Add a content hash (and lineage fields) to `WorkspaceApplyPlan` / `WorkspaceSnapshotFile`.** Unlocks dedupe, DAG, diff, bisect, and GitOps-style reconciliation. Claude calls this the single highest-leverage change; Codex independently identifies optional lineage fields as the smallest high-leverage schema addition.
2. **Evolve `AgentRestartRegistry.Row.resolve` from `String?` to a richer `RestartIntent` / `AgentRestartSpec` value type** (command + env + cwd + pre-input + readiness probe). All three reviewers identify this as the registry's fork-in-the-road moment before Phase 5 multi-agent rows arrive.
3. **Extract `WorkspaceMetadataKeys` into a shared module both `c11` and `c11-CLI` link** — kill the duplicated `"claude.session_id"` literal at `CLI/c11.swift:12639` before Phase 5 doubles every metadata key across two source-of-truth sites.

The compounding opportunity beneath all three: **make `WorkspaceApplyPlan` round-trippable, content-addressable, and lineage-aware**, then let pure transforms and named registries evolve around a stable envelope. This is the architecture that turns Phase 1 into branching agent rooms, whole-fleet restart, and cross-machine handoff.

---

## 1. Consensus Direction — Where Multiple Models Converge

### 1.1 Plan-as-IR is the load-bearing abstraction (Claude + Codex + Gemini)

All three reviewers independently identify `WorkspaceApplyPlan` as the real product. The pattern they want formalized:

- Claude: "Source -> Plan -> Executor as the only way to materialize a workspace."
- Codex: "Plan-as-IR is the strongest pattern. This should be named and defended as the workspace IR layer."
- Gemini: "Embedding the plan unmodified inside the snapshot file forces the converter to remain a pure function. Impurity is delayed until execution."

**Action:** Name the IR in code and docs. Move `WorkspaceSnapshotSource` to its own file; document the `@MainActor` capture / nonisolated convert / off-main store cascade as the canonical pattern; teach the skill that snapshots and blueprints share the same plan primitive.

### 1.2 Content hash + lineage fields on the envelope (Claude + Codex)

Both reviewers identify this as the smallest, highest-leverage schema move. Claude pushes the content hash explicitly (~30 LOC, sortedKeys SHA256); Codex pushes optional lineage fields (`parentSnapshotId`, `branchId`, `restoredFromSnapshotId`, `captureReason`). They compose: the hash is the dedupe primitive, the lineage fields make the DAG navigable, and together they become the foundation for `c11 list-snapshots --tree`, diff, bisect, and "branch from this room."

### 1.3 The restart registry is too small — make it strategy-shaped (all three)

- Claude: `AgentRestartSpec { command, workingDirectory, environment, preInputBytes, notes }`.
- Codex: `RestartIntent { command, workingDirectory, environment, requiresMetadata, readinessProbe, privacyNotes, fallback }`.
- Gemini: Make the registry dynamic via a config file — `terminal_type` -> shell command — so users onboard new agents without recompiling.

**Synthesis:** introduce a value-typed return (`RestartIntent` / `AgentRestartSpec`), keep a `String`-literal initializer for back-compat, AND eventually allow the rows to be data-driven (Gemini's TOML/JSON path) so Phase 5 doesn't require a Swift recompile per agent.

### 1.4 Cross-machine portability is the obvious next mutation (all three)

- Claude: "Snapshots get a content-addressable layer" → `c11 restore https://...`, `s3://`, `c11://machine-b:7878/...`.
- Codex: "Portable workspace bundles" with named anchors (`$repoRoot`, `$home`, `$workspaceRoot`) and bundled markdown.
- Gemini: "A snapshot generated on a laptop sent to a high-powered build server natively bootstraps remote-agent topologies."

The blocker all three flag: `SurfaceSpec.workingDirectory` and markdown `filePath` are absolute strings (`Sources/WorkspaceApplyPlan.swift:67,74`). The transform layer is the right home for portability rewrites.

### 1.5 Time-travel / event-sourced workspaces (all three)

- Claude: `WorkspaceSnapshotJournal` subscribing to `SurfaceMetadataStore` / `PaneMetadataStore` / `TabManager` mutations; coalesce deltas into envelopes; "5-second-RPO workspaces."
- Codex: "Time-travel workspaces. Every significant change emits an auto snapshot with lineage. Scrub through workspace history."
- Gemini: "`c11 snapshot --watch` socket event for snapshot deltas — the prerequisite for time-travel debugging."

This is the natural payoff of the lineage + hash + restart-spec investments above.

### 1.6 Snapshot diff and merge (Claude + Codex)

- Claude: `c11 snapshot diff <id1> <id2>` — structural plan-to-plan diff.
- Codex: "Workspace diff and merge. Take layout from A, session handles from B."

Falls out for free once content hashes and lineage exist.

### 1.7 Pane metadata first-class in the IR (Codex, supported by Claude's anti-pattern note)

Codex flags pane metadata attached to "first surface in a pane" as a clever Phase 1 compatibility bridge that becomes fragile when plans are edited, diffed, or generated externally. Claude flags the same shape from a different angle (the walker accumulating state). Both want a stable plan-local pane ID with optional pane metadata in `LayoutTreeSpec.PaneSpec` before agent-generated plans proliferate.

### 1.8 Lattice / mailbox integration as the cross-system flywheel (Claude + Codex)

- Claude (M5): Auto-file snapshots as Lattice task artifacts when `lattice.task_id` is in pane metadata.
- Codex: "Restart coordinator from mailbox topology" — orchestrators first, then workers, then watchers, using `mailbox.subscribe`/`mailbox.delivery` as the dependency graph.

Different angles on the same idea: c11 metadata is becoming the capability bus; downstream systems (Lattice, Mycelium, mailbox routing) get to reason about workspace state as data.

---

## 2. Best Concrete Suggestions — Ranked by Leverage

Items confirmed against code by at least one reviewer, ordered by ratio of payoff to implementation cost.

### Phase 2 horizon (do now / next phase)

1. **Add `contentHash: String` to `WorkspaceApplyPlan`** (~30 LOC). `Sources/WorkspaceApplyPlan.swift` is `Codable + Equatable`; `WorkspaceSnapshotStore.write` already uses `.sortedKeys` (`Sources/WorkspaceSnapshotStore.swift:103`). Hash function reuses that exact pipeline. Compounds into dedupe, DAG, diff, bisect, GitOps reconciliation. *(Claude S1, confirmed.)*

2. **Add optional lineage fields to `WorkspaceSnapshotFile` and `WorkspaceSnapshotIndex`.** `parentSnapshotId`, `branchId`, `restoredFromSnapshotId`, `captureReason`. Optional keys preserve old files. List UI stays flat until a graph view exists. *(Codex S1, confirmed at `Sources/WorkspaceSnapshot.swift:27,80`.)*

3. **Extract `WorkspaceMetadataKeys.swift` into a shared module both targets link.** Kills the `"claude.session_id"` literal duplication at `CLI/c11.swift:12639` vs `Sources/WorkspaceMetadataKeys.swift:29`. Phase 5 (codex/opencode/kimi) gets to add ONE entry per agent instead of TWO. *(Claude S2, confirmed.)*

4. **Replace `Row.resolve -> String?` with `RestartIntent` / `AgentRestartSpec`.** Provide a `String`-literal back-compat initializer so today's `"cc --resume \(id)"` rows are unchanged. New rows can carry env, cwd, pre-input bytes, readiness probes. Critical before Phase 5 stuffs multiple TUI behaviors into a single closure. *(Claude S6 + Codex S2, both confirmed; Gemini agrees on registry-as-leverage.)*

5. **Add a debug-build warning when `params["restart_registry"]` is non-empty but `AgentRestartRegistry.named(...)` returns nil.** Today a typo (`"phase01"`) silently falls through to Phase 0 behavior; the operator gets a fresh shell with no diagnostic. Append to `ApplyResult.warnings` — non-fatal but visible. *(Claude S3, confirmed at `Sources/TerminalController.swift` v2SnapshotRestore handler.)*

6. **Make pane metadata first-class in `LayoutTreeSpec.PaneSpec`.** Plan-local pane ID + optional pane metadata directly on the pane, not piggybacked on the first surface. Keep first-surface read path as v1 compatibility shim. Versioned migration in `WorkspaceSnapshotConverter`. *(Codex S3, confirmed.)*

### Phase 3 horizon (strategic)

7. **Promote `WorkspaceSnapshotSource` to a fully public protocol in its own file.** Mostly access-level changes; payoff is that Phase 2 Blueprints land as another `WorkspaceSource` conformer instead of a parallel parser path. Document the `@MainActor` / nonisolated split + the test-fake convention. *(Claude S5, confirmed.)*

8. **Formalize a pure plan-transform pipeline inside the converter.** Ordered transforms: validate envelope -> migrate plan -> rewrite portability anchors -> redact secrets -> return `WorkspaceApplyPlan`. The converter already imports only Foundation; isolation properties hold. Keep `C11_SESSION_RESUME` at the CLI boundary, not in the converter. *(Codex S4, confirmed.)*

9. **Build `c11 list-snapshots --tree` and friends.** Group by `workspace_title`, filter by `--workspace`, `--since`, `--tag`. `WorkspaceSnapshotIndex` already carries `workspaceTitle` + `createdAt`; this is presentation-only over existing data. This is the flywheel ignition (see §4). *(Claude S7, confirmed.)*

10. **Document the "named-registry bridge" pattern** in `DECISIONS.md` (or equivalent). The pattern `Registry.named("phase1") -> .phase1` will recur for theme switchers, mailbox routing, key bindings. Naming it now saves the next architect a discovery cycle. Pure docs, zero code risk. *(Claude S8.)*

11. **Promote `pendingInitialInputForTests` from `#if DEBUG` to an internal/SPI seam** (or a `TerminalCommandSink` dependency). Today `#if DEBUG` blocks release-build test targets and CLI smoke harnesses. Codex agrees the current seam is acceptable for Phase 1 but flags the same long-term shape. *(Claude S4 ⚠️ size-impact verification needed; Codex S9 lower priority.)*

12. **Reserve namespace placeholders in surface metadata for Phase 2.** Add a no-op `scrollback_ref` / `history_id` slot so the schema is already expecting historical text data. *(Gemini S2, needs exploration.)*

### Phase 5+ horizon (longer arc)

13. **Snapshot sets / multi-workspace manifests.** A `WorkspaceSnapshotSet` capturing many workspace IDs + focus/order is the primitive for "restart my whole agent fleet after app relaunch." `origin.autoRestart` already anticipates this. Keep the single-workspace primitive clean; layer the manifest above it. *(Codex S6.)*

14. **Portable workspace bundles with named anchors.** Map absolute paths to `$repoRoot`, `$home`, `$workspaceRoot`, `$artifactRoot`; bundle local markdown alongside the envelope. Lives as a transform before apply. *(Codex S5, design pass needed for missing files / security.)*

15. **Workspace diff CLI (`c11 snapshot diff <a> <b>`).** Pure-decoder JSON tree diff over the plan: added panes, changed titles, changed mailbox subscriptions, changed session IDs. Redact sensitive metadata by default. *(Codex S8 + Claude exp #12.)*

16. **Lattice integration: auto-file snapshots as task artifacts.** Listen for `lattice.task_id` in pane metadata; on `c11 snapshot`, post the file to the Lattice task. Cheap end-to-end (file copy + API call). High operator value: instant "what was the team doing on this task" replay. Could land as a Lattice consumer of a c11 hook OR a c11 hook with a Lattice destination. *(Claude M5 / S13.)*

17. **Property-based fixture fuzzing.** With content hashes (item 1), assert that `fuzzed-plan -> executor -> captured -> converter -> executor` is a fixed point. Rock-solid invariant for the whole `Plan` ABI; the existing fixture set is the seed corpus. *(Claude L5.)*

18. **Restart registry deprecation lane.** Today the wire carries `"phase1"`; future renames (`"v1"`?) shouldn't bump the wire format. Build aliasing now (`Registry.named("phase1") == Registry.named("v1")`). 5 lines + a doc note. *(Claude L4.)*

---

## 3. Wildest Mutations — Creative / Ambitious Ideas Worth Exploring

Grouped where multiple reviewers converge; standalone where a single reviewer reaches farthest.

### 3.1 Plan-as-prompt — agents author their own world (Claude M6 + Gemini wild idea)

- **Snapshot as system-prompt payload (Gemini):** Pipe the snapshot JSON into a new LLM agent as its system prompt. "Here is the exact state of your world when you were suspended. Resume." It becomes structured memory.
- **Plan-emitting agents (Claude M6):** A higher-up agent (Lattice planner, Mycelium router) emits a Plan; the executor materializes it; the resulting workspace is snapshotted. The snapshot is the agent's *fingerprint* of the workspace it asked for — replayable, diffable, distributable. Plan-as-data becomes the contract between intelligence and runtime.

These compose into a single mutation: **the agent ecosystem reads, writes, and exchanges Plans as the lingua franca of workspace state.** The biggest mutation in the entire trident.

### 3.2 The "Inception" mutation — agents snapshot their own swarm (Gemini)

Grant agents the `c11 snapshot` capability. An agent in one pane snapshots its surrounding workspace, serializes it, sends it as a message to another swarm: "Spin up this identical topology and finish the task." Cross-machine agent migration as a one-line agent move (Claude's M4 says the same thing from the operator's seat).

### 3.3 Snapshot DAG + git-shaped workflows (Claude M1, M3)

Once content hashes + lineage exist:
- `c11 list-snapshots --tree` shows the DAG.
- `c11 snapshot diff <a> <b>` shows what changed.
- `c11 restore --from <a> --replay-onto <b>` performs a workspace **rebase**.
- `c11 snapshot bisect <good> <bad> "test_command"` walks the DAG, restores each candidate, runs the test, narrows to where things broke. **`git bisect` for workspace state.**

### 3.4 Capture-on-event triggers (Claude M2)

`--on-event surface-close` (restore the workspace as it was 10 seconds ago), `--on-event idle`, `--on-event mailbox-receive`. Cheap with the journal (item §2.3.5 below); without it, fine for low-frequency triggers, wasteful for high-frequency ones.

### 3.5 Workspace event sourcing / journal (Claude §4)

`WorkspaceSnapshotJournal` subscribing to `SurfaceMetadataStore` / `PaneMetadataStore` / `TabManager` mutations; persist deltas to `~/.c11-snapshots/<ulid>.journal`; coalesce periodically into full envelopes. Restore = "load envelope + apply deltas." 5-second-RPO workspaces; crash recovery with milliseconds of state loss. Needs a bigger spike — the metadata stores would need to expose change-event streams, which they don't today.

### 3.6 `c11 restore --as-overlay` (Claude M7)

Restore not as replacement but as overlay. Layer snapshot's surface metadata, mailbox state, and titles onto a new ephemeral workspace ID — but keep pointers to the *original* live panels. Run two snapshots side-by-side as overlays, watching how the same panes evolve under different metadata regimes. Useful for comparing two Claude-Code sessions in parallel, or for "did the mailbox routing make sense?"

### 3.7 Restart choreography from mailbox topology (Claude M8 + Codex)

The registry stops being "how do I restart this agent?" and becomes "how does this swarm of agents come back to life?" — a small DSL for choreographing rehydration. Dependencies (`watcher restarts after driver`), parallelism (`fan out three reviewers from this one transcript`), fanout (`every surface with terminal_type=opencode resumes against the same upstream task`). Codex frames this as inferring the dependency graph from `mailbox.subscribe` / `mailbox.delivery` metadata — orchestrators first, then workers, then observers.

### 3.8 Continuous reconciliation / GitOps for workspaces (Claude §6)

Adopt mode: given a live workspace and a snapshot of *what it should look like*, compute the diff and apply it. Hot-reload snapshots into the current workspace; drive the workspace from version-controlled snapshots in a project (à la `lattice dashboard`'s expected layout); the operator's local workspace converges to a remote authoritative spec. **GitOps for workspaces** — the executor + plan are 80% of the way there.

---

## 4. Leverage Points and Flywheels

### 4.1 The primary flywheel — capture + browse + navigate (Claude)

1. **Capture is cheap and high-fidelity** -> operators snapshot more often.
2. **More snapshots** -> more proof points for fidelity, more demand for browse/search.
3. **Browse/search demand** -> list / index / DAG views get built (item §2.3.3, §2.3.9).
4. **DAG views** -> operators *navigate* between snapshots, not just restore the most recent.
5. **Restore-to-arbitrary-point becomes the default** -> `c11 restore` becomes the *primary* way operators move between contexts.
6. **Restore-as-default** -> snapshot capture becomes part of every session-end ritual, feeding step 1.

**Ignition step:** make `c11 list-snapshots` so good that operators discover new use cases for it. Sort orders, metadata filters, `--dry-run` previews.

### 4.2 The metadata flywheel (Codex + Gemini, same loop framed twice)

1. Agents write richer metadata because c11 makes metadata visible and useful.
2. Snapshots preserve that metadata, making restored rooms more faithful.
3. Faithful restore encourages operators to use c11 for more agent fleets.
4. More fleets produce more metadata conventions, mailbox topologies, restart policies.
5. Smarter snapshots make restore more valuable, raising the value of writing more metadata.

**Spin condition:** keep the schema small but make the transform layer powerful. Don't push every new feature into the snapshot file; make the envelope stable, then let pure transforms and registry strategies evolve around it.

### 4.3 The agent-adoption externality (Claude)

The agent-restart contract creates a positive externality: any agent that adopts c11 metadata conventions (`terminal_type` + `<agent>.session_id`) earns "snapshot/restorable" status with no other work. Today that's just Claude Code via `terminal_type=claude-code`. The moment a second agent (codex via Phase 5) adopts the same shape, the registry's *value doubles for free*. **Document this as a pitch** to any agent author considering c11 integration.

### 4.4 The 30-LOC compounding move

Across all three reviews, the single change with the highest ratio of payoff to cost: **`WorkspaceApplyPlan.contentHash`** (item §2.1). It compounds into:
- Dedupe (§1)
- DAG / lineage (M1 + Codex S1)
- Diff (Codex S8)
- Bisect (M3)
- GitOps reconciliation (§6)
- Property-based fuzz invariants (L5)
- "Captured == read-back" proven cheaply

Claude's exact phrasing: "do that one, and the rest start writing themselves."

### 4.5 The IR-naming move

Across all three reviews, the highest-leverage *documentation* move: **name the workspace IR** in the skill, in `DECISIONS.md`, and in the source. Once agents reason in plan transforms instead of shell scripts, the entire ecosystem orients around `WorkspaceApplyPlan` as the contract. Pure docs cost; architectural payoff.

---

## 5. Anti-Patterns to Catch Early (Consensus)

1. **Walker-as-struct-with-mutating-methods.** `LiveWorkspaceSnapshotSource.Walker` is readable today; by Phase 4 (browser history? markdown scrollback? PTY scrollback?) it'll need an explicit `CaptureContext` value passed through recursion. Refactor before it gets big. *(Claude.)*

2. **Stringly-typed `restart_registry` with silent fall-through.** Visible-but-non-fatal warning is the right register. *(Claude S3.)*

3. **Duplicated metadata key literals across CLI and app.** The `claude.session_id` precedent must not repeat for codex/opencode/kimi. *(Claude S2 + Codex.)*

4. **Pane metadata via first-surface convention.** Encodes pane state through a surface ordering convention. Fine for round-trip; fragile for editing, diffing, branching, and externally-generated plans. *(Codex S3.)*

5. **`#if DEBUG` test seams that don't compose.** Right idea, wrong wrapping. SPI / internal access without `#if` is the long-term shape. *(Claude S4 + Codex S9.)*

6. **Absolute paths in `SurfaceSpec`.** Fixtures already encode `/tmp/plan.md`. Cross-machine portability requires a portability transform — design before it ossifies. *(Codex.)*

---

## 6. Bottom Line

The unanimous read across all three models: **Phase 1 quietly establishes a workspace runtime where `WorkspaceApplyPlan` is the executable IR.** Every future feature should be "another `Source`, another row in the registry, another optional envelope field, another pure transform" — never a carve-out. Hold that discipline and by Phase 5 c11 will own the cleanest workspace primitive on any platform, and the snapshot file becomes the lingua franca for "what is a workspace" across machines, agents, and time.

The two investments that compound the most:
1. **`WorkspaceApplyPlan.contentHash` + optional lineage fields** — 30 to 60 LOC that unlocks half the wild ideas in this synthesis.
2. **`RestartIntent` value type** — keeps Phase 1 behavior identical while preventing Phase 5 from collapsing under per-agent special cases.

Do those two, name the IR, and the flywheel starts spinning on its own.
