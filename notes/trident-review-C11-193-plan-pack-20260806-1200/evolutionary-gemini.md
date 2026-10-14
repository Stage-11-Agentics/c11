# Evolutionary Plan Review

### Executive Summary
The biggest opportunity here isn't merely preventing a failure state (an agent getting confused by operating in a worktree). It's establishing a foundation for "Context-Aware" or "Task-Scoped" agents. By enforcing explicit intent for worktrees, this plan paves the way for agents that understand when they are operating in ephemeral, branch-specific environments versus the main repository. This unlocks the potential for safer, parallel agent workflows where the environment dictates the agent's boundaries.

### What's Really Being Built
Beneath the surface, this plan is building an **Environmental Boundary Enforcer**. It moves the agent's relationship with the file system from an "implicit assumption" to an "explicit contract." It implicitly recognizes that a git worktree is a fundamentally different class of environment (usually task-scoped and ephemeral) than a main checkout (usually persistent), and builds the first infrastructure to treat them differently. This is the first step toward agents that understand their Git topological context.

### How It Could Be Better
Right now, the plan treats the git worktree probe simply as a boolean trigger for a rejection guard. It could be much more powerful. 
Instead of just rejecting the implicit cwd and discarding the context, the `git rev-parse` probe can extract rich context (branch name, worktree path, common path) and *preserve* it. If a user explicitly allows the worktree launch via `--cwd`, the agent should be initialized with the knowledge that it's in a linked worktree and know its branch. 
Furthermore, the error message on rejection should not just stop the user; it should teach them the mental model of Workspaces (tying into sibling ticket C11-194) and provide copy-pasteable commands for their likely intents.

### Mutations and Wild Ideas
*   **Mutation 1: Auto-Sandboxed Ephemeral Agents.** What if, when explicitly launching in a worktree, the agent automatically shifts to an ephemeral, worktree-scoped memory/session state? When the worktree is deleted, the agent's state for that task is naturally garbage collected. The worktree becomes the definitive boundary for a "Sub-Agent."
*   **Mutation 2: Automatic Resolution to Main.** Instead of rejecting the launch outright, what if `launch-agent` automatically resolves the CWD to the `--git-common-dir` when invoked implicitly inside a worktree? It could emit a warning: "Redirecting agent to main repository context. Use `--cwd .` to operate in this specific worktree."
*   **Mutation 3: Interactive Clarification.** If invoked from an interactive terminal (TTY) and the guard trips, intercept the rejection with a prompt: "You are in worktree branch `X`. Do you want to launch a task-specific agent here, or launch the main agent in `<common-dir>`?"

### What It Unlocks
Once this guard is in place and users are forced to be explicit about worktrees, it unlocks:
*   **Safe Parallelism**: Multiple agents can run across different worktrees on the same machine without stepping on each other's toes, modifying the wrong branches, or sharing contaminated git context.
*   **Context-Bound Tasking**: Tying into C11-194, a "Workspace Root" could intentionally be set to a specific worktree, making the Workspace implicitly a temporary "Task Space".

### Sequencing and Compounding
The plan currently sequences: Probe -> Reject -> Allow Explicit.
The optimal sequence is: Probe -> Extract Context -> Determine Precedence (Worktree Guard vs. C11-194 Workspace Root) -> Reject/Allow -> *Pass Context to Agent*.
By passing the context, the effort spent probing the git tree compounds into making the agent smarter about its environment, rather than the probe just being a disposable gatekeeper. You do the work to find the git-dir, don't throw it away.

### The Flywheel
The flywheel here is: Explicit Context -> Safer Actions -> Higher Trust -> More Delegated Parallel Tasks.
By forcing the user to explicitly define when they are in a worktree, the system prevents catastrophic mistakes (like force-pushing the wrong branch because the agent thought it was in `main`). This builds user trust. Higher trust means the user is more likely to spin up multiple worktrees with multiple agents working in parallel, feeding back into the need for robust environmental guards.

### Concrete Suggestions
1.  **Enrich the Probe Payload**: Modify step 2 so the probe doesn't just check for a worktree, but explicitly returns a structured object (e.g., `GitContext(isWorktree: Bool, commonDir: String, branch: String)`).
2.  **Context Injection**: If the user provides `--cwd` and bypasses the guard, inject this `GitContext` into the agent's initialization payload so it is immediately aware of its ephemeral environment.
3.  **Coordinate Precedence with C11-194**: Explicitly define what happens if a C11-194 "Workspace Root" is configured to point *inside* a linked worktree. Does the workspace root act as an explicit override (like `--cwd`)? It logically should, as it represents user intent.
4.  **Actionable CLI Rejection**: Design the rejection output to explicitly suggest the two most likely desired paths, utilizing the data from the probe:
    ```
    Agent launch blocked: Inherited directory is a linked git worktree (branch: feature-x).
    - To launch an agent specifically for this worktree, run: c11 launch-agent --cwd .
    - To launch your main workspace agent, run: cd /path/to/main && c11 launch-agent
    ```

### Questions for the Plan Author
1.  How should this worktree guard interact with the new "Workspace Root" feature from C11-194? If a Workspace Root is implicitly inherited but points to a worktree, does it bypass this guard because the root is "explicitly" set?
2.  When a user explicitly bypasses the guard with `--cwd`, should the agent be made aware that it is operating in a linked worktree, or should it remain ignorant of its environment?
3.  Are there plans to eventually support ephemeral agent state (like temporary task memory) tied directly to the lifecycle of these linked worktrees?
4.  Should the probe differentiate between a detached HEAD in a worktree versus a named branch, since a detached HEAD might indicate an even more transient state?