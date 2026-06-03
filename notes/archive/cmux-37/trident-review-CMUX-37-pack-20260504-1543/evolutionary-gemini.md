## Evolutionary Code Review
- **Date:** 2026-05-04T15:43:00Z
- **Model:** Gemini
- **Branch:** cmux-37/final-push
- **Latest Commit:** HEAD
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary/Exploratory
---

**What's Really Being Built**
This PR doesn't just add a "save/restore" feature; it establishes an **Infrastructure-as-Code (IaC) primitive for the local operator environment**. By moving blueprints from opaque JSON to human-authorable Markdown with YAML frontmatter, the workspace becomes a versionable, shareable artifact. You are building the "Terraform for local agentic workflows" — a declarative substrate where the layout, tools, and context of an agent swarm are defined entirely in text. The addition of the snapshot manifest (`WorkspaceSnapshotSet`) elevates the abstraction from "a single window" to "the entire session state".

**Emerging Patterns**
- **Polymorphic Interfaces:** The `c11 restore` command now gracefully handles both atomic snapshots and set manifests. This pattern of transparently upgrading the capability of a command without changing its surface area is strong and should be maintained.
- **Metadata as the Integration Seam:** `claude.session_id` and the `mailbox.*` keys are carrying the weight of session resumption without polluting the core `WorkspaceApplyPlan` layout schema. This decoupling is an emerging pattern that proves the metadata architecture is robust.
- **Graceful Degradation of Diagnostics:** Introducing severity levels (`.info` vs `.failure`) in the `ApplyFailure` pipeline prevents automation from panicking over expected round-trip behaviors (like `metadata_override` or `working_directory_not_applied` for seed terminals).

**How This Could Evolve**
- **Dynamic / Templated Blueprints:** Currently, blueprints are static files. The next evolutionary step is dynamic evaluation (e.g., injecting `$CWD`, `$GIT_BRANCH`, or even running a lightweight setup script before materializing the plan). This turns blueprints into executable environments.
- **Workspace State Reconciliation:** Since blueprints define the *desired* state and snapshots capture the *actual* state, `c11` could eventually perform a "diff" (like `terraform plan`) to show how a live workspace has drifted from its origin blueprint, or offer to "re-apply" missing panes without destroying the whole workspace.
- **Remote / Headless Orchestration:** The `WorkspaceApplyPlan` is now expressive enough that it could be sent over the wire to a remote daemon. You could "apply" a blueprint on a headless cloud instance and attach to it later.

**Mutations and Wild Ideas**
- **Bidirectional Live-Sync Blueprints:** What if opening a blueprint in the `markdown` surface made it live-linked? Splitting a pane in the UI automatically updates the YAML frontmatter in the file; editing the YAML live-updates the UI splits. The blueprint becomes the control plane.
- **Time-Traveling Workspaces:** With the `--all` snapshot manifests, you are one step away from a "scrubber" interface. If snapshots are taken periodically, an operator could scrub back in time across their entire c11 session, reviving closed contexts.
- **Agent-Authored Environments:** Give agents the explicit skill to propose or write new `WorkspaceBlueprintMarkdown` files. If an agent realizes it needs three parallel terminals and a browser to complete a task, it authors the blueprint and asks the operator to instantiate it.

**Leverage Points**
- **The Markdown Parser (`WorkspaceBlueprintMarkdown.swift`):** This is a massive leverage point. Now that c11 can parse markdown to build UI, you can extend the frontmatter schema to include things like `required_skills`, `env_vars`, or `agent_roles`.
- **The Snapshot Manifest (`WorkspaceSnapshotSet`):** By grouping snapshots into sets, you've created a "session" concept. This makes it trivial to implement features like "Export Session as Zip" to share a complete reproduction environment with another developer.

**The Flywheel**
The flywheel here is **Shareability**. As blueprints become easy to read and write (Markdown), operators will share them in repositories (`.c11/blueprints/`). As more repos have blueprints, new operators will instantly get the perfect environment when they clone a repo. This drives adoption, which drives the need for more expressive blueprints, completing the loop.

**Concrete Suggestions**

1. **High Value: Blueprint Parameterization**
   Extend the Markdown parser to support basic variable substitution (e.g., `${REPO_ROOT}`, `${CURRENT_BRANCH}`). This makes repo-level blueprints infinitely more reusable across different operator machines without hardcoding absolute paths.
   ✅ Confirmed — The parser in `WorkspaceBlueprintMarkdown.swift` could easily perform a quick regex replacement pass over string values before returning the `WorkspaceBlueprintFile`.

2. **Strategic: "Drift" Detection (Plan vs. Live)**
   Implement a `c11 workspace diff` command that compares the currently active workspace against the blueprint it was spawned from (or a provided blueprint). This sets up the architecture for non-destructive, incremental layout updates in the future.
   ❓ Needs exploration — Would require tracking the "origin blueprint" in workspace metadata and writing a diffing engine for `WorkspaceApplyPlan`.

3. **Experimental: Bidirectional File Sync**
   Allow a workspace to be launched in "linked" mode (`c11 workspace new --blueprint foo.md --link`). Any layout changes made via `bonsplit` or terminal additions automatically serialize and overwrite `foo.md`.
   ❓ Needs exploration — High risk of overwriting operator comments in the markdown body, but incredibly powerful if the parser/writer can preserve the AST.

4. **Strategic: Expose Manifests to Agents**
   Update the `c11` skill so agents know about `c11 list-snapshots --sets`. An agent could be instructed to "save your progress" by invoking `c11 snapshot --all`, allowing the operator to safely pause complex, multi-agent orchestrations.
   ✅ Confirmed — Trivial addition to the `SKILL.md` file.