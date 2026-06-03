## Evolutionary Code Review
- **Date:** 2026-04-24T14:50:00Z
- **Model:** Gemini
- **Branch:** cmux-37/phase-1-snapshots-restore
- **Latest Commit:** 43807212
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary/Exploratory
---

### What's Really Being Built
c11 isn't just building a session manager; it's building an **Agent State Hypervisor**. By combining an immutable snapshot format (`WorkspaceSnapshotFile` wrapping `WorkspaceApplyPlan`) with a dynamic restart registry (`AgentRestartRegistry`), the application effectively enables "suspend and resume" for LLM agents. The workspace becomes a first-class workload primitive that can be detached from a physical machine, persisted, and re-hydrated. The snapshot is fundamentally the "call stack" for a distributed intelligence session.

### Emerging Patterns
- **Data-Driven Decoupling:** The `claude-hook` writes `claude.session_id` directly to surface metadata (`surface.set_metadata`). This makes the c11 metadata store the source of truth for an agent's process lifecycle, rather than fragile external dotfiles. This is a robust pattern for inter-process communication that should be encouraged.
- **The Pure/Impure Boundary:** Embedding the `WorkspaceApplyPlan` entirely unmodified within the `WorkspaceSnapshotFile` forces the converter to remain a pure function. Impurity (like synthesizing commands via the `AgentRestartRegistry`) is explicitly delayed until the exact moment of execution (`WorkspaceLayoutExecutor` step 7). This preserves identical behaviors for both hardcoded Blueprints and generated Snapshots.

### How This Could Evolve
- **Time-Travel Debugging for Agents:** Since taking a snapshot is cheap, c11 could emit a snapshot automatically every time an agent takes a destructive or significant action. This opens the door to rewinding a multi-agent orchestration session to any point in the past, viewing the exact context (browser tabs, markdown files), and forking the execution.
- **Cross-Machine Portability:** Because the converter is pure and uses no AppKit or environment reads, a snapshot generated on a laptop could be easily sent to a high-powered build server. Running `c11 restore` there would wake up the identical agents in the identical layout, natively bootstrapping remote-agent topologies.

### Mutations and Wild Ideas
- **Snapshot as a Prompt Payload:** What if the `WorkspaceSnapshotFile` JSON itself was piped into a new LLM agent as its system prompt? "Here is the exact state of your world when you were suspended. Resume." It becomes a structured memory payload.
- **The "Inception" Mutation:** Agents could be granted the `c11 snapshot` capability. An agent in one pane could snapshot its entire surrounding workspace, serialize it, and send it as a message to another agent swarm, asking "Can you spin up this identical topology and finish the task?"

### Leverage Points
- The `AgentRestartRegistry` is the critical leverage point. While currently hardcoded to `phase1` in Swift, making this registry dynamic (e.g., via a `.toml` or `.json` config file that maps `terminal_type` to shell commands) would allow users to onboard new agents instantly without recompiling c11.
- `WorkspaceApplyPlan`: Because Snapshots share this type with Blueprints, any layout feature (like default split ratios or pane backgrounds) added to Blueprints automatically enriches Snapshots, and vice versa.

### The Flywheel
The more agents integrate with c11, the richer the metadata hooks become. Richer metadata means `c11 snapshot` captures exponentially more complex system states perfectly. This flawless "save/load" capability makes c11 the most reliable environment for long-running agent tasks, encouraging even more agent developers to adopt the skill file and metadata API.

### Concrete Suggestions
1. **High Value**: Expose `AgentRestartRegistry` extensibility beyond Swift literals. Allow operators to define custom `terminal_type` → `command` mappings in a configuration file or via socket method, empowering the community to support custom agents immediately. ✅ Confirmed
2. **Strategic**: Add a placeholder `scrollback_ref` or `history_id` string to `SurfaceSpec` metadata. Even if Phase 1 doesn't capture the scrollback buffer, reserving the namespace primes the engine for Phase 2, ensuring the schema is already expecting historical text data. ❓ Needs exploration
3. **Experimental**: Implement `c11 snapshot --watch` or a socket event that automatically emits a lightweight snapshot delta whenever an agent updates surface metadata. This is the prerequisite for "Time-Travel Debugging". ❓ Needs exploration
