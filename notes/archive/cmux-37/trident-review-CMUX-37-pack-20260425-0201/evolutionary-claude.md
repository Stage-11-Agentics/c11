## Evolutionary Code Review

- **Date:** 2026-04-25T02:01:00Z
- **Model:** Claude Sonnet 4.6 (claude-sonnet-4-6)
- **Branch:** cmux-37/remaining-phases
- **Latest Commit:** 4e4ca5a8b1531bfc77529bc3663cdafeaa5cb11e
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary/Exploratory

---

## What's Really Being Built

The stated feature is "workspace persistence" -- Blueprints + Snapshots + session resume. But look past that.

What's actually being built is a **workspace grammar**. The `WorkspaceApplyPlan` schema is a declarative description of an entire multi-agent environment -- surface kinds, layout topology, metadata, restart commands, working directories, initial commands. It's already Codable, already versioned, already executable (via `WorkspaceLayoutExecutor`), already round-trippable (capture → serialize → deserialize → apply).

What CMUX-37 does is complete that grammar's I/O surface: you can now express a workspace in JSON, name it (Blueprint), timestamp it (Snapshot), share it (file), and have it re-materialized by the executor. The grammar is closed.

Nobody has named this yet: **c11 is shipping a workspace programming language**. The JSON schema at `docs/workspace-apply-plan-schema.md` is the spec. The three starter blueprints (`agent-room.json`, `basic-terminal.json`, `side-by-side.json`) are the "hello world" programs. `workspace.apply` is the runtime. `c11 snapshot --all` is the save-state instruction.

That reframing changes what's important to build next.

---

## Emerging Patterns

### Pattern 1: The walker/executor duality

`WorkspacePlanCapture` (capture) and `WorkspaceLayoutExecutor` (apply) are inverses. The extraction of `WorkspacePlanCapture` in Phase 3a formalized this -- both Snapshot and Blueprint now use the same serialization path. This is a genuinely clean abstraction that deserves a name: the **workspace round-trip invariant**. It should be documented and tested as a property: "capture followed by apply produces a workspace isomorphic to the original."

Currently the round-trip tests in `WorkspaceSnapshotBrowserMarkdownRoundTripTests.swift` verify Codable fidelity but don't verify executor fidelity (they don't execute the plan against a live workspace). That gap will matter when the executor grows.

### Pattern 2: Registry as command synthesis layer

`AgentRestartRegistry` is a pure resolver table -- no I/O, no AppKit, just a `[String: Row]` lookup. The `Row` closure receives `(sessionId, metadata)` and returns a shell command or nil. This pattern scales: future TUIs just add rows. It's already Sendable. The "phase1" name binding via `AgentRestartRegistry.named(_:)` means the wire protocol is decoupled from registry versions -- clean.

The emerging anti-pattern: the `--continue` flag existence for `opencode` and `kimi` is unconfirmed. The registry pattern is right; the flag values are guesses. This is an intentional best-effort design, but it means the registry has rows that may fail silently at runtime. The comments are honest about it. Consider adding a `confidence` field to `Row` (`.verified` / `.bestEffort`) as machine-readable signal for observability dashboards.

### Pattern 3: Source hierarchy as federation

Blueprints discover from three sources -- repo, user, built-in -- in priority order. The per-repo walk is git-discovery style (walks up from CWD until home). This is the same pattern git uses for `.gitignore`, npm uses for `.npmrc`, and many other tools use for config. It's the right pattern for a tool used across multiple projects. The emerging convention here: c11 is becoming config-file-aware at the workspace level.

The anti-pattern to catch early: `~/.config/cmux/blueprints/` is the user directory, but `WorkspaceBlueprintIndex.Source` has `user = "user"` and `WorkspaceBlueprintFile.swift` uses `.config/cmux/blueprints/` throughout. The `cmux` naming in the path is a legacy artifact -- this will cause confusion as the project completes its `cmux` → `c11` rename. The path should be `~/.config/c11/blueprints/` with a migration shim.

### Pattern 4: Metadata as the extensibility seam

`SurfaceSpec.metadata` and `SurfaceSpec.paneMetadata` are open-ended `[String: PersistedJSONValue]` maps. The `terminal_type` / `claude.session_id` / `mailbox.*` namespaces are examples of what fits there. This is the right extensibility model -- the schema doesn't need to know about every possible TUI or workflow; future information flows through metadata. The executor already validates reserved keys and emits typed warnings on collision.

The emerging issue: there's no discovery mechanism for what metadata keys exist in the ecosystem. An agent setting `terminal_type = "codex"` has to know to do that. A Blueprint file has to hardcode it. The metadata namespace is open but undiscoverable.

---

## How This Could Evolve

### The natural next step: parametric blueprints

The current blueprint format is static -- every field is fixed at authoring time. The obvious evolution is parametric blueprints: variables you fill in at `workspace new` time.

```json
{
  "name": "feature-branch",
  "parameters": [
    { "name": "branch", "prompt": "Branch name?" },
    { "name": "project_dir", "prompt": "Project directory?", "default": "." }
  ],
  "plan": {
    "workspace": { "title": "{{branch}}" },
    "surfaces": [
      { "id": "s1", "kind": "terminal", "working_directory": "{{project_dir}}" }
    ]
  }
}
```

The executor already takes a `WorkspaceApplyPlan` -- the parametric layer would sit between Blueprint loading and `workspace.apply`, substituting variables before the plan reaches the executor. The CLI picker could prompt for each parameter interactively (c11 already has stdin-reading picker infrastructure from `workspaceBlueprintPicker`).

This is the move that goes from "blueprint as named template" to "blueprint as reusable program."

### Agent-authored blueprints and the composability play

An agent today can call `workspace.export_blueprint` to capture its current workspace as a blueprint. That's powerful but one-directional. The evolution is: agents construct blueprints programmatically and call `workspace.apply` to spawn new workspaces from scratch, without first materializing a workspace to capture.

The infrastructure is already there -- `workspace.apply` takes a full `WorkspaceApplyPlan`. The missing piece is ergonomic: agents need a way to construct plans via the socket without building raw JSON. A `workspace.plan_builder` family of socket commands (or a fluent JSON API) would let agents express "give me a horizontal split with a terminal left and browser right" without knowing the full schema.

This points at c11 becoming a **workspace orchestration substrate for agent-driven multi-agent setups**. The operator sets up a blueprint; agents spawn and configure their own workspaces from it.

### Snapshot diff and merge

Right now snapshots are point-in-time captures. The natural evolution is snapshot diffing: given two snapshots, what changed? This would let the restart flow be smarter -- don't recreate surfaces that haven't changed, just restore state on existing surfaces.

The `WorkspacePlanCapture` walker already produces a normalized `WorkspaceApplyPlan`. Diffing two plans is tractable: compare layout trees structurally, compare surface specs by kind/metadata/position. An `ApplyResult` for a "diff-apply" would only describe what changed.

### Blueprint sharing as social/team feature

Blueprints are currently per-repo or per-user. The evolution is team/org sharing: a shared blueprints registry (e.g., a git repo, a URL, a Lattice workspace) that operators and agents pull from. The `WorkspaceBlueprintStore` source hierarchy already has the three-tier concept; adding a fourth `remote` source with a cache layer is the natural extension.

---

## Mutations and Wild Ideas

### Mutation 1: Blueprints as executable Lattice tasks

The `WorkspaceApplyPlan` JSON is already a description of multi-agent orchestration. A Lattice task could carry a blueprint as its `launch_spec` -- when the task is started, Lattice calls `workspace.apply` with the embedded plan and the agent's pane is configured from the spec.

This collapses "start a task" and "configure a workspace" into one action. The operator creates a Lattice task that includes the workspace layout; assigning the task to an agent both queues the work and spawns the right environment.

### Mutation 2: Blueprint-as-CI-environment

The workspace schema describes a running environment (terminals with commands, browsers at URLs, markdown files open). With minor additions, a blueprint could describe a CI check environment -- "this test requires a terminal running `npm start` and a browser pointed at localhost:3000." The executor already sends commands to terminals. A "CI mode" apply (no UI, headless, capture stdout) would make blueprints the unit of reproducible environment specification.

### Mutation 3: The workspace as a diff target for AI

Because `WorkspacePlanCapture` produces a stable JSON representation of workspace state, an LLM could reason over it directly. "Here's my current workspace state (JSON). What should I add? What surfaces suggest I'm doing X?" The workspace becomes a context artifact the agent can read and propose mutations to.

This is subtle but significant: most agent tools observe the environment through process-level affordances (terminal I/O, screenshots). A structured JSON description of workspace topology is a different affordance -- cheaper, lossless, manipulable.

### Mutation 4: Registry rows with capability negotiation

Instead of hardcoding `codex --last\n`, registry rows could query the TUI for its resume capabilities at restore time:
```
codex --list-sessions | parse → pick session → codex --session <id>
```
This is a bigger lift but would make resume genuinely session-accurate rather than globally best-effort. The Row closure signature already accepts `metadata` as a full map -- the capability negotiation result could cache there.

### Mutation 5: Blueprint hot-reload

A blueprint file is just JSON on disk. If the `WorkspaceBlueprintStore` watched its sources for changes (using `DispatchSource`/`FSEvents`), the CLI picker could refresh live without re-running `c11 workspace new`. More ambitiously, if an operator edits a blueprint while it's applied, `workspace.apply` could compute a diff and hot-patch the live workspace. This is the "live reload for workspace layout" idea.

---

## Leverage Points

### 1. The `WorkspaceApplyPlan` version field is your API surface ✅ Confirmed

`WorkspaceLayoutExecutor.supportedPlanVersions` is a `Set<Int>` and `validate()` is `nonisolated` (pre-main-thread). The versioning seam is already in place. The leverage: any non-breaking addition to the plan schema (new optional fields) is free to ship; agents that write v1 plans continue working against a v2 executor. Breaking changes (new required fields, semantics changes) bump the version and fail fast. This is the right design.

**Leverage move:** Document the versioning contract explicitly in `docs/workspace-apply-plan-schema.md` as a stability promise. Agents that depend on the schema need to know what's stable.

### 2. `WorkspaceBlueprintStore.merged(cwd:)` is the single discovery entry point ✅ Confirmed

All blueprint discovery routes through one method. Adding a fourth source (remote, team, etc.) requires adding one `result.append(contentsOf: ...)` call to `merged(cwd:)` and implementing the source. The tests use `directoryOverride:` injection, so new sources are testable in isolation.

**Leverage move:** Add a `sources` parameter to `merged(cwd:)` that lists which source types to include, defaulting to all. This allows `c11 snapshot --all` and `workspace new` to filter source types without global state.

### 3. The `AgentRestartRegistry.named(_:)` binding is your upgrade path ✅ Confirmed

The wire protocol sends `"phase1"` and the app resolves it at runtime. Adding a "phase2" registry that includes session-accurate codex resume doesn't require a schema change -- just add a case to `named(_:)`. Operators running old snapshots (written with "phase1") automatically get phase1 behavior; new snapshots that emit "phase2" get better resume.

**Leverage move:** As soon as confirmed CLI flags exist for opencode/kimi, ship a "phase2" registry with verified rows. The "phase1" name becomes a permanent compatibility alias, not a version that needs maintenance.

### 4. `WorkspacePlanCapture` as a cross-project primitive ❓ Needs exploration

The walker is now cleanly separated from both Snapshot and Blueprint paths. If other parts of c11 need to inspect workspace topology (e.g., for sidebar telemetry, for a "current workspace state" socket query, for workspace-level analytics), they can call `WorkspacePlanCapture.capture(workspace:)` rather than walking bonsplit directly. This concentrates the AppKit/bonsplit surface area in one place.

Consider: `workspace.get_plan` socket command that returns the current workspace's `WorkspaceApplyPlan` as JSON. Agents could then read, reason about, and propose modifications to the workspace topology without any new walker code.

---

## The Flywheel

The self-reinforcing loop that this PR sets in motion:

1. **Blueprints ship with c11** -- operators get three starter layouts on day one, no configuration required.
2. **Operators use them and customize them** -- `workspace export-blueprint` lets them capture their actual workflow as a named template.
3. **Blueprints accumulate in `~/.config/cmux/blueprints/`** -- the picker grows richer with each capture.
4. **Blueprints get committed to repos** -- the per-repo `.cmux/blueprints/` discovery means team members and agents share layouts.
5. **Agents learn to apply blueprints** -- `workspace.apply` + `workspace.list_blueprints` are already socket-addressable; once agents know to use them (via skill update), they configure their own environments from team blueprints.
6. **Better agent outputs flow from better environments** -- agents running in well-configured workspaces (right surfaces, right metadata, restart commands pre-loaded) produce more reliable work.
7. **Operators refine blueprints based on agent performance** -- the cycle closes.

The flywheel's weakest link right now is step 5: agents can already call these socket commands, but the skill file hasn't been updated to teach them about blueprints (Phase 4 was noted as done externally, not in this PR). The flywheel stalls if agents don't know the commands exist.

---

## Concrete Suggestions

### High Value

**1. Rename `.config/cmux/blueprints/` to `.config/c11/blueprints/`** ✅ Confirmed
- **Where:** `WorkspaceBlueprintStore.swift` line 92, `TerminalController.swift` line 4524, CLI code in `c11.swift` around `runWorkspaceExportBlueprint`
- **Why:** The `cmux` naming is legacy. The directory will confuse operators as the cmux-to-c11 rename completes. Do it now before blueprints accumulate in user home directories.
- **Risk:** Needs a one-time migration: check for old directory, move contents if present. Add shim in `perUserBlueprintURLs()`.

**2. Add `workspace.get_plan` socket command** ❓ Needs exploration
- **Where:** New method in `TerminalController.swift`, same pattern as `v2WorkspaceExportBlueprint`
- **Why:** Agents need to read workspace state as structured JSON, not just capture it to disk. This enables "what is my current workspace?" without side-effects.
- **Sketch:**
  ```
  Request: {"method": "workspace.get_plan", "params": {"workspace_id": "..."}}
  Response: {"plan": <WorkspaceApplyPlan JSON>}
  ```
  One `v2MainSync` block calling `WorkspacePlanCapture.capture(workspace:)`, then `JSONEncoder().encode(plan)`.

**3. Verify or flag unconfirmed CLI flags in `AgentRestartRegistry`** ✅ Confirmed
- **Where:** `Sources/AgentRestartRegistry.swift` lines 124-138
- **Why:** `opencode --continue` and `kimi --continue` may not exist. If they don't, agents that expect resume will get an error or a fresh session silently. The current comments acknowledge best-effort but there's no runtime failure signal.
- **Suggestion:** Add a `verified: Bool` property to `Row` and emit a `restart_registry_best_effort` warning (not failure) in `WorkspaceLayoutExecutor` when a best-effort row fires. Agents see it in `ApplyResult.warnings` without it blocking execution.

### Strategic

**4. Parametric blueprint variables** ❓ Needs exploration
- **Where:** New file `Sources/WorkspaceBlueprintParameters.swift`, called between `WorkspaceBlueprintStore.read()` and `workspace.apply` in both CLI and socket handler
- **Why:** Static blueprints are useful; parametric blueprints are powerful. The picker already prompts users interactively; adding a parameter-prompt pass before applying is a small increment to the UX with a large multiplier on blueprint reusability.
- **Schema addition:** Optional `parameters: [{name, prompt, default}]` in `WorkspaceBlueprintFile`. The executor never sees this -- parameters are resolved before the plan is handed to the executor.

**5. Blueprint round-trip as an invariant test** ✅ Confirmed
- **Where:** Add to `c11Tests/WorkspaceBlueprintFileCodableTests.swift` or new file
- **Why:** The current tests verify Codable fidelity (encode/decode) but not executor fidelity (capture → apply → capture produces the same plan). The invariant should be: `capture(apply(plan)) ≅ plan`. This would catch any executor behavior that drifts from the capture path.
- **Note:** Requires a test harness with a fake `TabManager` and `WorkspaceLayoutExecutorDependencies` -- more infrastructure, but it's the test that guarantees the round-trip promise.

**6. Versioning contract in schema docs** ✅ Confirmed
- **Where:** `docs/workspace-apply-plan-schema.md`
- **Why:** The schema is the public API for agents, Blueprint authors, and future tooling. The stability promise ("optional fields are additive, new required fields bump the version, breaking semantics bump the version") should be explicit. Without it, agents that hardcode v1 schemas have no contract to rely on.
- **Sketch:** Add a "Versioning" section with the contract, the current supported version set, and guidance on what triggers a version bump.

### Experimental

**7. `workspace.watch` socket command for live topology events** ❓ Needs exploration
- **Why:** Agents could subscribe to workspace topology changes (surface added, removed, metadata changed) and react without polling `workspace.get_plan`. The c11 event/notification infrastructure likely already supports something like this. The blueprint format is the data model; events would carry `WorkspaceApplyPlan` deltas or full snapshots.
- **Risk:** Non-trivial to implement correctly with bonsplit's AppKit-bound state model. Start with a simple "workspace changed" event with no payload and let agents re-query if needed.

**8. Blueprint as Lattice task `launch_spec`** ❓ Needs exploration
- **Why:** If a Lattice task can carry a blueprint URL or inline plan, the workflow "create task, assign to agent" automatically configures the workspace. This collapses project management and environment setup into one primitive.
- **Where:** Lattice task schema (separate repo), c11 Lattice plugin
- **Risk:** Cross-repo coordination required. Worth prototyping in the `lattice-stage-11-plugin`.

**9. Source confidence levels for `WorkspaceBlueprintIndex`** ⬇️ Lower priority than initially thought
- Adding `verified`/`bestEffort` confidence to registry rows is the right call. Doing the same for blueprint sources (repo-local blueprints are "trusted", built-in are "verified") is less important because all three sources produce the same executor inputs -- there's no security boundary crossed.

---

## Validation Notes

- **#1 (rename `.config/cmux/blueprints/`)**: Verified the path in three places -- `WorkspaceBlueprintStore.swift:92`, `TerminalController.swift:4524`, and `CLI/c11.swift` export path. All hardcode `cmux`. The `WorkspaceBlueprintIndex.Source` enum values (`"repo"`, `"user"`, `"built-in"`) are wire format and don't embed the path -- safe to rename the path independently.

- **#2 (`workspace.get_plan`)**: The pattern matches `v2WorkspaceExportBlueprint` exactly -- `v2MainSync` → `WorkspacePlanCapture.capture` → encode → return. One difference: no file write needed, just return the JSON object. No architectural conflicts.

- **#3 (unconfirmed flags)**: Confirmed the registry rows in `AgentRestartRegistry.swift:123-138`. The comments acknowledge best-effort. Emitting a warning via `ApplyResult.warnings` when a best-effort row fires is compatible with the executor's existing warning machinery (already used for `restart_registry_declined` at line ~222 in `WorkspaceLayoutExecutor.swift`).

- **#4 (parametric blueprints)**: The CLI picker already reads from stdin with numbered selection (`workspaceBlueprintPicker`). Parameter prompting would follow the same pattern. The `WorkspaceBlueprintFile` struct would gain an optional `parameters` field without breaking existing decoders (Codable handles missing optional fields gracefully).

- **#5 (round-trip invariant test)**: The fake source pattern from `WorkspaceSnapshotCapture.swift` (`FakeWorkspaceSnapshotSource`) shows the test harness exists. Extending it to test the full capture → apply → capture cycle requires a fake `TabManager` -- that's the existing pattern from `WorkspaceLayoutExecutorDependencies` in Phase 0 tests.

- **#6 (schema docs versioning contract)**: `docs/workspace-apply-plan-schema.md` exists and is well-structured. Adding a versioning section is purely additive.
