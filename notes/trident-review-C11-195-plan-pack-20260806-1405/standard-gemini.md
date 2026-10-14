# Standard Plan Review

### Executive Summary
This plan is sound, pragmatic, and accurately identifies the architectural root cause: configuration lookup diverges from actual spawn behavior because it relies on incomplete path resolution. By explicitly deferring to C11-194’s centralized cwd resolver, the plan guarantees that the project configuration lookup and the child process working directory remain perfectly synchronized. This is exactly the right approach.

### The Plan's Intent vs. Its Execution
The intent is to ensure `.c11/agents.json` is located using the true directory the agent will run in, rather than silently defaulting to the app's process root when `--cwd` is omitted. The execution maps perfectly to this intent: it replaces localized path logic with the centralized resolved path and plumbs that same path into surface creation to eliminate divergence.

### Architectural Assessment
The problem decomposition is correct. C11-194 owns the domain of path resolution (explicit `cwd` → workspace root → surface inherited), and C11-195 correctly positions itself as a pure consumer of that value. Building a parallel resolution chain for configuration lookup would have been an architectural mistake, so the dependency sequencing here is strong.

### Is This the Move?
Yes. It fixes a silent failure mode where users expect their project-level agent configurations to apply but find them ignored on inherited launches. De-duplicating this logic by waiting for C11-194 is the most robust path forward.

### Key Strengths
- **Single Source of Truth**: Consuming the C11-194 resolver guarantees that the config lookup cwd and the child process cwd will always match, eliminating a brittle synchronization point.
- **Dependency Sequencing**: Explicitly declaring C11-194 as a blocker prevents duplicate work and merge conflicts across the sibling tickets.
- **Testing Approach**: Adding a scratch-backed logic test that specifically verifies the project config is found from the resolved path (and asserting that the process cwd fallback is ignored) will confidently lock in this behavior.

### Weaknesses and Gaps
- **App-process cwd Fallback**: The plan states it will "use the app-process cwd only when no explicit, workspace-root, or launching-surface path exists at all." For a macOS GUI app, `FileManager.default.currentDirectoryPath` is often `/` or the app bundle directory. While pushing this to the bottom of the fallback chain makes it less likely to be hit, it might not be a meaningful location to search for a project config. (If C11-194 retains this as the ultimate fallback, then C11-195 is just inheriting it, but it’s worth questioning if the user's home directory `~` would be a safer ultimate fallback).
- **Threading Subtlety**: In `v2AgentLaunch`, configuration lookup currently happens off-main (`DefaultAgentProjectConfig.find`). However, C11-194's centralized resolver will likely need to read `@MainActor` state (like `TabManager` or `TerminalPanel`) to resolve inherited workspace roots or surface cwds. The plan does not mention how the cwd resolution and config lookup will be safely sequenced across these threading boundaries.

### Alternatives Considered
- **Alternative 1: Look up config on the surface's final cwd after creation.** This would require changing the flow so that the config is applied *after* the surface is created. This is flawed because the surface needs the config to know *how* to launch the agent (e.g., resolving the command). The plan correctly keeps config lookup prior to surface creation.
- **Alternative 2: Re-implement cwd inheritance just for config lookup.** The plan correctly avoids this code duplication by strictly depending on C11-194.

### Readiness Verdict
**Ready to execute**, pending minor clarifications on threading.

### Questions for the Plan Author
1. **Threading:** `v2AgentLaunch` currently performs its config lookup off-main. Because C11-194's resolver must interrogate the launching surface or workspace root (which are likely `@MainActor` state), how will C11-195 sequence the config lookup? Will C11-194 provide a synchronous off-main snapshot, or will the config lookup logic need to be hoisted into a main-sync block (or an async await)?
2. **Ultimate Fallback:** The plan mentions using the app-process cwd as the absolute last resort. Given that the GUI app process cwd is often the app bundle or `/`, would it make more sense for the ultimate fallback to be the user's home directory (`~`)? Or does C11-194 already handle this?
3. **C11-194 Dependency:** Given that C11-194 was recently reset and is currently `in_progress` again, will you be stacking this branch on top of C11-194's WIP branch, or waiting for it to merge to `main` first?
