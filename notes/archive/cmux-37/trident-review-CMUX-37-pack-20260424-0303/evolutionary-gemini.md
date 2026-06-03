## Evolutionary Code Review
- **Date:** 2026-04-24T03:03:00Z
- **Model:** Ugemini (Gemini Experimental)
- **Branch:** cmux-37/phase-0-workspace-apply-plan
- **Latest Commit:** e4f60b98
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary/Exploratory
---

### What's Really Being Built

On the surface, this is an infrastructure ticket for "Workspace persistence" (Blueprints and Snapshots). Under the hood, **you are building a declarative, one-shot Native UI Reconciler.** 

By moving away from imperative shell choreography (`c11 workspace new`, `c11 split`, `c11 set-metadata` in a loop) and toward `WorkspaceLayoutExecutor`, you are inventing a "Terraform for Desktop Environments." The `WorkspaceApplyPlan` is the desired state; the AppKit layer is the projection. Once you decouple the intent from the mutation, you've created a primitive where the workspace is just a function of the plan.

### Emerging Patterns

1. **Virtualization of Identity:** The introduction of plan-local `SurfaceSpec.id` and its translation to `surface:N` (live refs) is the dawn of a Virtual DOM approach for the workspace. The architecture naturally wants to treat the AppKit objects as disposable projections of the metadata store and the `LayoutTreeSpec`.
2. **Fail-Forward UI State (Anti-Pattern vs Pragmatism):** The executor's refusal to rollback a partially applied workspace on failure is a pragmatic choice for Phase 0. However, this pattern risks leaving orphaned ghost states. An emerging pattern here is "observable failures" — writing the failure state back into the `Workspace.metadata` so that a recovery agent or the operator can resume the plan later.
3. **The Metadata Bus as State:** Standardizing on the string-only `mailbox.*` dictionary as a first-class persistence citizen in `WorkspaceApplyPlan` formalizes the metadata layer as the primary communication bus. The workspace isn't just visually composed; it's syntactically bound.

### How This Could Evolve

The most powerful evolution of this code lies in the Phase 0+ TODO: `applyTo(existing:Workspace)`. 

Right now, the plan is a "Big Bang" creation primitive. If `WorkspaceLayoutExecutor` evolved to compute a structural diff between a live `ExternalTreeNode` (the current bonsplit tree) and a `LayoutTreeSpec`, `workspace.apply` would become **idempotent and reconciliatory**. 
- An agent could emit a new Blueprint mid-flight to dynamically summon tools.
- A "watch" agent could continuously reconcile the workspace to ensure its required panes remain active and positioned correctly.
- A user could tweak a `.cmux/blueprints/*.md` file and have the workspace morph in real-time without closing active terminal sessions.

### Mutations and Wild Ideas

- **Agent Swarm Playbooks:** Since `WorkspaceApplyPlan` supports `command` injection and metadata wiring on boot, it is one step away from being an orchestration definition. You could define a "Swarm Blueprint" where the first pane runs a dispatcher, and subsequent panes are auto-wired to `mailbox.subscribe` to the dispatcher's topics, spawning an entire microservice-like environment of LLMs talking to each other instantly.
- **Headless Layout Execution:** What if `WorkspaceLayoutExecutor` could execute *without* a visible window? Generating a headless virtual session, snapshotting the output, and destroying it. The executor is currently heavily tied to the `TabManager` and AppKit. Decoupling the instruction generation from the AppKit mutation could allow server-side or headless workspace simulations.
- **Composable Blueprints:** Introduce an `$import: "path/to/other/plan.json"` directive within the `WorkspaceApplyPlan` struct. This allows shared tool configurations (e.g., a standardized debugging split) to be injected into any workspace automatically.

### Leverage Points

- **The `AnchorPanel` abstraction in `WalkState`:** It currently binds directly to AppKit (`TerminalPanel`, `newXSplit`). If you extract this into an interface (`WorkspaceSurfaceDriver`), you gain disproportionate value: you can write tests that don't need XCTest performance budgets because they run entirely in memory against a mock driver, simulating complex split logic without spinning up Ghostty surfaces.
- **The Phase 0 acceptance fixture:** It acts as a performance guardrail (< 2_000ms). If `WorkspaceApplyPlan` becomes more complex, this test will break. Pushing the parsing and AST compilation entirely off-main thread (leaving only strict AppKit `addSubview`/`insert` calls for the main actor) will make the next 10 features scalable.

### The Flywheel

**The Infrastructure-as-Code Flywheel:**
1. You provide a declarative CLI (`c11 workspace-apply`).
2. Agents learn to write `WorkspaceApplyPlan` JSON or Markdown to structure their own environment (e.g., an agent opening a scratchpad and a live-preview browser).
3. The environment becomes richer, allowing agents to solve harder problems.
4. Agents generate more complex playbooks/blueprints as a result, which get saved as Snapshots.
5. The operator benefits from a library of highly optimized agent-created environments.

### Concrete Suggestions

1. **[High Value] Abstract the AppKit Mutator (The Reconciler Pattern):**
   Separate the `WalkState.materialize` step into two distinct phases: 
   Phase 1: Compute the desired operations (e.g., `[CreatePane(id), SplitPane(id, vert), SetMetadata(id)]`).
   Phase 2: Execute operations on `TabManager`.
   *Why:* This makes testing purely structural and sets up the future diffing/reconciliation engine without tangling it in AppKit state.
   *Validation:* ✅ Confirmed. The current DFS tree traversal could easily yield an array of enums instead of executing `workspace.newTerminalSplit` directly.

2. **[Strategic] Idempotent Updates (`applyTo(existing:)`):**
   In `Sources/WorkspaceLayoutExecutor.swift`, instead of treating `applyToExistingWorkspace` as a hack to bypass the seed panel, design it to compute a diff. If a pane with the same `SurfaceSpec.id` already exists in the live tree, update its metadata/title instead of recreating it.
   *Why:* Sets up the hot-reload advantage.
   *Validation:* ❓ Needs exploration. `ExternalTreeNode` (Bonsplit) and `LayoutTreeSpec` have different node identities, so mapping plan-local IDs to live pane IDs during a re-apply requires careful stable ID tracking.

3. **[Experimental] First-Class Plan Emitting by Agents:**
   Define a standard where an agent can output a JSON block wrapped in a specific sequence (e.g., `<<<CMUX_APPLY_PLAN...>>>`) to stdout. The terminal controller intercepts this and feeds it to `v2WorkspaceApply`. 
   *Why:* Allows agents to dynamically adapt their environment without needing to call the CLI socket directly.
   *Validation:* ❓ Needs exploration. Requires terminal output scraping which might violate the "unopinionated about the terminal" principle, but could be wildly powerful.

4. **[High Value] `ApplyResult.failures` State Serialization:**
   When a partial failure occurs, write the `ApplyResult.failures` array back into the root `Workspace.metadata["apply_failures"]`.
   *Why:* If an agent or UI needs to know the workspace didn't fully materialize (e.g. a broken split), it can query the workspace metadata later instead of losing the transient socket response.
   *Validation:* ✅ Confirmed. Step 9 in `WorkspaceLayoutExecutor.apply` could easily inject this into `workspace.setOperatorMetadata` before returning.
