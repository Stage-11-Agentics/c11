# Evolutionary Plan Review: C11-195 (launch-agent cwd config lookup)

### Executive Summary
The C11-195 plan fixes a bug where agent project configurations are ignored because the GUI app's process root is used instead of the contextually relevant directory. While the plan correctly routes C11-194's resolved directory path into the configuration lookup, the real opportunity is evolving this from a simple bug fix into the foundation for **Context-Aware Agent Environments**. By formalizing how agents inherit configurations from their directory tree, we can unlock directory-specific agent personas, workspace trust boundaries, and cascaded configurations that make the agent feel native to the specific codebase it's operating in.

### What's Really Being Built
Beneath the surface, this plan isn't just fixing a `cwd` argument; it is building **Spatial Configuration**. It shifts the agent from being a globally configured entity to a spatially aware entity whose instructions, models, and capabilities morph based on where the user summons it. It formally establishes the `.c11/agents.json` file not just as a static config file, but as a "local boundary" that defines the rules of engagement for that specific part of the filesystem.

### How It Could Be Better
1. **Bounded Directory Walks (Stop at the Root)**: Currently, `DefaultAgentProjectConfig.find` walks up to 64 directories searching for `.c11/agents.json`. If C11-194 introduces a formal "Workspace Root," the walk should intelligently terminate at this root. Walking blindly all the way to `/` or `~` risks leaking configurations from generic parent directories into isolated workspaces.
2. **Context-Aware Resolution Object, Not Just a String**: The plan proposes passing the "resolved effective launch cwd" into `DefaultAgentProjectConfig.find(from:)`. Instead of passing a raw string path, pass the entire `cwdResolution` struct (which carries provenance: explicit, workspaceRoot, or inherited). This allows the lookup logic to make smarter decisions—for example, treating a `workspaceRoot` configuration differently than an `inherited` subdirectory configuration.
3. **Visibility of the "Winning" Config**: If the configuration changes based on the launch directory, users will inevitably get confused about *why* the agent is behaving a certain way. The plan should include exposing the path of the applied `.c11/agents.json` file in the UI (e.g., in the agent settings panel or a tooltip) and in `--json` diagnostic output.

### Mutations and Wild Ideas
- **Sub-Project Personas (The Monorepo Mutation)**: In a monorepo, a backend directory might have a `.c11/agents.json` specifying "You are a Rust expert," while the frontend directory specifies "You are a React expert." By relying on spatial configuration, developers could naturally summon the right expert just by navigating directories and launching an agent.
- **Cascading Configurations**: Instead of "first match wins," what if configurations merged? The workspace root defines the default model (e.g., Claude 3.5 Sonnet) and cost limits, but a nested `.c11/agents.json` in a specific microservice directory appends specific architectural instructions to the system prompt. 
- **Workspace Trust Boundary**: Arbitrary filesystem walks that automatically load configurations are a known security vector (cf. VS Code Workspace Trust). If I clone a malicious repo and launch an agent inside it, can the local `agents.json` configure a malicious tool or system prompt? This plan is the exact right place to introduce the concept of "Untrusted Workspaces" that require explicit user consent before loading a local `.c11/agents.json`.

### What It Unlocks
- **Frictionless Onboarding**: Teams can commit `.c11/agents.json` to their repositories. New developers opening the repo in C11 instantly get the team's preferred models, system prompts, and tool configurations without manually tweaking settings.
- **Context-Specific Tools**: Once the agent's identity is tied to the directory, it unlocks the ability to define directory-specific tools (e.g., a `.c11/scripts/` folder that the agent can execute, which changes depending on the workspace).

### Sequencing and Compounding
1. **C11-194 (Workspace Root)**: Establishes the anchor and intent.
2. **C11-193 (Linked Worktree Warning)**: Validates that provenance metadata works.
3. **C11-195 (This Plan - Config Lookup)**: Uses the anchor and provenance to load config.
   *Crucial adjustment:* Don't just consume the string. Consume the provenance. If the provenance is `.workspaceRoot`, look *only* there. If it's `.explicit` or `.launchingSurface`, walk up, but *stop* at the workspace root if one is defined. 
4. **Future**: C11-195 unlocks the ability to build the "Workspace Trust" feature on top of this lookup boundary.

### The Flywheel
**The Configuration Flywheel**: As spatial configurations become reliable (because they actually resolve correctly based on the exact path), more users will commit `.c11/agents.json` to their repositories. As more repositories contain these configurations, the out-of-the-box experience of C11 improves for all users cloning those repositories. This reduces configuration friction, leading to better agent interactions, which incentivizes teams to further refine their `.c11/agents.json` and advocate for its usage.

### Concrete Suggestions
1. **Refactor `DefaultAgentProjectConfig.find` to accept a boundary constraint.** 
   ```swift
   static func find(
       from cwd: String?,
       stoppingAt workspaceRoot: String? = nil,
       fileManager: FileManager = .default
   ) -> DefaultAgentConfig?
   ```
   This prevents the walk from traversing beyond the explicitly set C11-194 workspace root, sandboxing the agent's context to the intended workspace.
2. **Add a `source_config_path` attribute to the `AgentLaunchStats` or JSON payload.** When debugging agent behavior, the user (or C11 itself) needs to know if a project config was applied and *where* it was found.
3. **Log a warning if parsing fails.** The plan says "Parse failures are silently swallowed." While we shouldn't brick the terminal flow, swallowing parse errors silently makes debugging a malformed `agents.json` incredibly frustrating for the user. Surface the parse error as a non-fatal warning in the agent's initial launch output or diagnostic logs.

### Questions for the Plan Author
1. **Boundary Limits:** Should the directory walk in `DefaultAgentProjectConfig.find` be bounded by the C11-194 `workspaceRoot`? If we don't bound it, could an agent in a workspace accidentally inherit a configuration from `~/Projects/.c11/agents.json`?
2. **Security Model:** Are we concerned about automatic, silent ingestion of `.c11/agents.json` in cloned, untrusted repositories? Does this plan need to consider a Workspace Trust gate or a prompt?
3. **Merge vs. Override:** The current implementation is strict override ("first match wins"). Are there use cases where a user wants their global default (e.g., preferred LLM model) to merge with the project's default (e.g., project-specific system prompt)?
4. **Visibility:** How will the user know that a specific `.c11/agents.json` has hijacked their global agent settings? Should we expose the loaded config path in the UI or CLI launch output?
5. **Parse Errors:** Are we sure we want to *silently* swallow JSON parsing errors in `.c11/agents.json`? Could we instead emit a warning so developers know their config is broken instead of wondering why it isn't applied?