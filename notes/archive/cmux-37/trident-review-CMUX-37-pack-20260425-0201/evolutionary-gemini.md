## Evolutionary Code Review
- **Date:** 2026-04-25T02:01:00Z
- **Model:** Gemini (google/gemini-pro)
- **Branch:** cmux-37/remaining-phases
- **Latest Commit:** 4e4ca5a8
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary/Exploratory
---

### What's Really Being Built

This branch isn't just adding persistence; it's laying the foundation for a **Workspace-as-Code** engine. The core capability being created is the ability to represent the entire c11mux workspace—its layout, surfaces, and metadata—as a declarative, serializable, and transportable artifact: the `WorkspaceApplyPlan`.

This transforms the workspace from an ephemeral UI state into a programmable, reproducible, and shareable piece of infrastructure. It's the architectural move that allows operators and agents to treat the command center itself as a tool to be scripted, versioned, and composed.

### Emerging Patterns

1.  **`WorkspaceApplyPlan` as the Universal Currency:** This `Codable` struct is the most important pattern to emerge. It's the lingua franca for describing a workspace, used by Snapshots (for ephemeral state capture) and now Blueprints (for reusable templates). The extraction of `WorkspacePlanCapture` solidifies this, creating a canonical "compiler" from live state into this intermediate representation.

2.  **Declarative Materialization:** The `WorkspaceLayoutExecutor` acts as the "runtime" that can take a `WorkspaceApplyPlan` and make it real. This separation of declaration (the Plan) from execution (the Executor) is a powerful architectural pattern that enables all other features in this branch.

3.  **Filesystem-as-Database for Blueprints:** The `WorkspaceBlueprintStore`'s multi-source discovery (repo-local `.cmux/`, user-global `~/.config/cmux/`, built-in app resources) is a smart, convention-over-configuration pattern. It makes Blueprints feel like a natural extension of the filesystem, discoverable and easy to manage without a complex database.

### How This Could Evolve

The "Workspace-as-Code" concept can be pushed much further.

1.  **Parameterized Blueprints:** The current Blueprints are static. The next evolutionary step is to make them templates. An agent or operator could provide parameters at launch time.

    ```bash
    # fictitious flag
    c11 workspace new --blueprint 'my-project' --param 'branch=feature-x'
    ```

    The `WorkspaceApplyPlan` could support simple string substitution in `command`, `url`, `filePath`, and `working_directory`. This would dramatically increase the reusability of Blueprints.

2.  **Composable Blueprints & Overlays:** What if you could apply a Blueprint on top of an existing workspace, or compose multiple Blueprints?

    ```bash
    # Fictitious flags
    c11 workspace apply-blueprint 'debug-tools' --workspace 'current'
    c11 workspace new --blueprint 'react-dev' --with 'storybook'
    ```

    This would require the `WorkspaceLayoutExecutor` to handle merging plans, potentially adding a new split or a tabbed surface to an existing layout.

3.  **A Smarter Restart Registry:** The `AgentRestartRegistry` is currently a static, best-effort map. This capability wants to evolve into a dynamic, intelligent **Session Revival Agent**. Instead of a hardcoded command, it could be a script or a small, embedded function that receives the surface metadata and returns a precise restart command based on runtime context (e.g., reading shell history, checking for lockfiles). This would move the responsibility from a static table in c11 to a more flexible, agent-specific logic.

### Mutations and Wild Ideas

1.  **Live Blueprints:** What if a blueprint wasn't a static file, but a URL that resolves to a `WorkspaceApplyPlan`?

    ```bash
    c11 workspace new --blueprint https://blueprints.example.com/for-user/acme
    ```

    The `WorkspaceBlueprintStore` could be extended to fetch and cache remote blueprints. This would enable teams to share and update standard workspace layouts centrally.

2.  **Markdown Frontmatter Blueprints:** The plan originally considered this, and it's a powerful idea. A file like `my-workspace.md` could contain YAML frontmatter for the `WorkspaceApplyPlan` and the body could be a scratchpad or instructions. This would make blueprints more human-friendly and self-documenting. `WorkspaceBlueprintStore` already looks for `.md` files; this would complete the picture.

3.  **Git-backed Blueprint Palettes:** The blueprint store could recognize a directory of blueprints as a git repository and offer to pull updates. This would create a mechanism for teams to subscribe to and share "palettes" of common layouts.

### Leverage Points

1.  **`WorkspaceBlueprintStore` Discovery:** The filesystem discovery logic is the single biggest leverage point. Expanding it (e.g., to support URLs, git repos) has a high ROI. It's the entry point for all blueprint-related features.

2.  **The CLI Picker:** The interactive picker (`runWorkspaceBlueprintNew`) is currently a simple numbered list. This UI is a leverage point. It could be enhanced with search, filtering by source (`--source built-in`), or previewing the blueprint's structure.

3.  **`WorkspacePlanCapture`:** This shared helper is a critical abstraction. Any improvement to its capture fidelity (e.g., capturing more state like scroll position, shell history) immediately benefits both Snapshots and Blueprints.

### The Flywheel

Shareable Blueprints create a network effect.
1.  An operator creates a useful Blueprint and shares it with their team.
2.  The team finds it useful, which encourages them to create and share their own Blueprints.
3.  As the library of Blueprints grows, c11mux becomes more valuable, as new workspaces for common tasks can be spun up instantly.
4.  This incentivizes more people to use c11mux and create Blueprints, spinning the flywheel faster.

The key is to make sharing as frictionless as possible. Git-backed or URL-based blueprints are the fuel for this flywheel.

### Concrete Suggestions

#### High Value
- **✅ Confirmed:** **Implement Parameterized Blueprints.**
  - **Suggestion:** Introduce a simple templating mechanism (e.g., `{{VAR_NAME}}`) in `WorkspaceApplyPlan` fields like `command`, `url`, and `working_directory`. Add a `--param 'KEY=VALUE'` flag to `c11 workspace new`. This would provide a massive boost in utility for a relatively small implementation cost, primarily in `WorkspaceLayoutExecutor`.
- **✅ Confirmed:** **Add a `--description` to `c11 workspace new`.**
  - **Suggestion:** The `WorkspaceBlueprintFile` has a `description` field, but it can only be set when exporting. Allow setting it on creation (`c11 workspace new --blueprint ... --description "..."`) to improve the metadata of user-created blueprints. This is a small but important usability improvement in `CLI/c11.swift`.

#### Strategic
- **✅ Confirmed:** **Evolve Snapshots and Blueprints into a single type.**
  - **Suggestion:** A `WorkspaceSnapshotFile` is just a `WorkspaceBlueprintFile` with a `createdAt` timestamp, a `snapshotId`, and an `origin`. Consider merging them into a single `WorkspaceDocument` type with a `type` field (`snapshot` or `blueprint`). This would simplify the codebase by removing redundant `Codable` structs and allow for a more unified set of tools for working with both. The `WorkspacePlanCapture` already unifies the capture logic; this would unify the data model.
- **❓ Needs exploration:** **Support Markdown Frontmatter Blueprints.**
  - **Suggestion:** In `WorkspaceBlueprintStore`, when a `.md` file is found, parse the YAML frontmatter for a `WorkspaceApplyPlan`. This would make blueprints more human-readable and self-documenting, realizing the vision from the original plan. It would require adding a YAML parsing dependency.

#### Experimental
- **❓ Needs exploration:** **Prototype a "Live Blueprint" provider.**
  - **Suggestion:** In `WorkspaceBlueprintStore`, add a proof-of-concept remote provider that can fetch a blueprint from a URL. This would open the door to centralized blueprint management and dynamic workspace generation, which is a huge step forward for the "Workspace-as-Code" vision.
- **⬇️ Lower priority than initially thought:** **Flesh out the AgentRestartRegistry.**
  - **Suggestion:** The current implementation is divergent and minimal. While a "smarter" restart is a good long-term goal, the current "best-effort" approach is probably sufficient for now. The focus should be on the more foundational Blueprint and Plan-related enhancements.

This branch represents a significant step forward in the architectural vision for c11mux. By focusing on the `WorkspaceApplyPlan` as a core primitive and building tooling around it, the project is creating a powerful, programmable command center. The suggestions above aim to amplify this direction.
