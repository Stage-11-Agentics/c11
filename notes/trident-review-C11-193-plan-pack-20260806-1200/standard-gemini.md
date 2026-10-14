# C11-193 Plan Review: Standard

### Executive Summary
The plan is highly pragmatic and addresses a sharp edge in the multi-agent `launch-agent` workflow. It accurately identifies that linked git worktrees in `c11` are typically dedicated to a specific agent's task (like the Lattice Orchestrator workflow). Implicitly launching a new agent into another agent's worktree is almost always an accident that causes state corruption or confusion. By making worktree inheritance an explicit-only action (via `--cwd`), the plan creates a robust guardrail without blocking intentional overrides. The plan is sound, structurally correct, and ready to execute.

### The Plan's Intent vs. Its Execution
**Intent:** Prevent accidental agent launches into another agent's dedicated git worktree, while keeping the door open for explicit overrides.
**Execution:** The plan executes this perfectly by adding a `git rev-parse` probe to differentiate linked worktrees from standard directories or submodules, intercepting the inherited `cwd` resolution path, and surfacing an actionable error. The execution aligns with the intent exactly. It targets `launch-agent` precisely and respects the `--cwd` flag.

### Architectural Assessment
The problem decomposition is correct. 
- Steps 1 & 4 anchor the change in pure-logic tests around the `CwdParamResolution` seam.
- Step 2 isolates the git probe logic (comparing `--git-dir` and `--git-common-dir`).
- Step 3 wires the probe specifically to the *inherited* path, leaving the explicit path untouched.

One architectural friction point: `CwdParamResolution.resolve(_:)` is currently a pure function that does no I/O beyond `FileManager`. Injecting a `git` shell-out into this flow introduces subprocess I/O. To maintain the "pure-logic testable" mandate of step 4, the linked-worktree probe must either be injected via a protocol (e.g., `GitWorktreeProber`), or run as a separate step outside the pure enum (e.g. in `TerminalController.v2ResolveCwdParam`), or it must avoid `Process` entirely by parsing the `.git` file directly. (Note: `MetadataDeriver` / `GitContextResolver` exists in the codebase and provides exactly this seam, returning a `ResolvedGitContext`).

### Is This the Move?
Yes, this is definitely the move.
Given the Lattice Orchestrator workflow pattern (one worktree per delegator), agent concurrency will naturally lead to agents trying to spawn sub-agents from their own panels. If a sub-agent inherits the worktree, it might start modifying files while the parent is also working, or the parent might close the ticket and delete the worktree out from under the sub-agent. Making worktree inheritance an error forces the orchestrator (or operator) to explicitly declare intent.

### Key Strengths
- **Precision:** By comparing `--git-dir` and `--git-common-dir`, the probe cleanly differentiates a linked worktree from a main checkout (and importantly, from a submodule, which also uses a `.git` file).
- **Explicit override:** It doesn't break the CLI contract; `--cwd` still works perfectly. It only stops *implicit* inheritance, which is where the accidents happen.
- **Actionable error:** Promising an actionable error with the branch name gives the caller exact context on *why* the launch failed and how to recover (e.g., "Use --cwd to override").

### Weaknesses and Gaps
- **The pure-logic constraint of `CwdParamResolution`:** If the `git rev-parse` probe uses `Process`, it cannot be unit-tested in `c11LogicTests` without a mock. The plan needs a seam (like a protocol) if it intends to use `Process`, or it needs to use `FileManager` to parse the `.git` file.
- **Interaction with C11-194 (Workspace Roots):** C11-194 introduces a workspace root directory. When `launch-agent` rejects the panel's worktree cwd, what happens? Does it immediately error, or does it fall back to the new Workspace Root? The plan should explicitly specify that a rejected linked-worktree results in an immediate *hard error* rather than silently falling back to the workspace root. Silent fallbacks cause spatial confusion ("Where did my agent spawn?").

### Alternatives Considered
- **Alternative 1: File-based parsing.** Instead of spawning `git rev-parse`, we could read the `.git` file directly using `FileManager`. In a linked worktree, `.git` is a file containing `gitdir: /path/to/.git/worktrees/<branch>`. By reading this file and checking for the `/worktrees/` substring, we achieve the same goal with zero subprocess overhead and perfect `c11LogicTests` compatibility.
- **Alternative 2: Silently fall back to Workspace Root (from C11-194).** If the panel is in a worktree, ignore it and use the workspace root. *Rejected* because silent behavior changes are confusing for CLI users. The explicit error proposed in the plan is much better.

### Readiness Verdict
**Ready to execute**, pending minor clarifications on the I/O boundary of the git probe and the exact error-vs-fallback behavior alongside C11-194.

### Questions for the Plan Author
1. **I/O in pure logic:** `CwdParamResolution.resolve` is currently pure and fast (using only `FileManager`). Shelling out to `git rev-parse` introduces subprocess I/O. Do you want to inject a prober protocol to keep it testable, use the existing `GitContextResolver`, or parse the `.git` file directly via `FileManager` to avoid the subprocess entirely?
2. **Interaction with C11-194:** When the inherited cwd is rejected because it's a linked worktree, should the CLI return a hard error, or should it silently fall back to the Workspace Root Directory being introduced in C11-194? (A hard error seems preferable for clarity, but it should be stated explicitly).
3. **Where does the probe run?** Will this probe run in the CLI client before sending the socket request, or on the server side (`TerminalController`) during socket payload resolution? Doing it server-side is more robust against race conditions, but client-side might provide faster terminal feedback.
