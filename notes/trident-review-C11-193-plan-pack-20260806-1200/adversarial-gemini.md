# Adversarial Plan Review

### Executive Summary
The plan aims to protect users from a specific workflow footgun (launching agents in another agent's Lattice worktree) by introducing git-specific knowledge into the c11 launch path. While the intent is good, the plan introduces a significant architectural smell: it tightly couples a general terminal multiplexer to a highly specific git workflow (git worktrees) and likely introduces a synchronous subprocess (`git rev-parse`) into the launch critical path. The single biggest issue is the potential interaction with the CLI-to-Server boundary and C11-194: distinguishing between an "inherited" and "explicit" CWD is notoriously fragile if the CLI implicitly resolves and forwards the path.

### How Plans Like This Fail
- **The "Invisible Override" Anti-pattern:** CLIs often resolve default values (like `$PWD`) before sending the payload over the wire to the server. If `c11 launch-agent` resolves the inherited cwd on the client side and sends `--cwd /path/to/worktree`, the server cannot distinguish this from the user explicitly typing `--cwd /path/to/worktree`. The plan fails to specify *where* this distinction is made and how it survives the CLI/socket boundary.
- **Subprocess in the Hot Path:** Spawning `git` to probe the filesystem during an agent launch introduces latency and new failure modes (e.g., `git` is missing, PATH is wrong, or the filesystem is a slow network mount).
- **False Positives:** Git submodules also use a file-based `.git` pointer instead of a directory. While `--git-common-dir` can distinguish them, any flaw in the probe logic will block users from launching agents inside submodules, which is a massive usability regression.

### Assumption Audit
- **Assumption:** `git` is available, fast, and safe to run synchronously. (Load-bearing. If `git` hangs, agent launch hangs. In a terminal multiplexer, this is unacceptable.)
- **Assumption:** The system can reliably distinguish "inherited" from "explicit" cwd. (Load-bearing. If the shell or CLI normalizes this before the check, the guard either fires when it shouldn't or fails to fire at all.)
- **Assumption:** Linked worktrees are almost always "another agent's active tree." (Cosmetic/Strategic. Human operators use git worktrees heavily too. We are penalizing standard git usage to protect a specific Lattice automation pattern.)
- **Assumption:** The `cwd` resolution seam is stable. (Vulnerable. C11-194 is actively rewriting this exact seam to introduce Workspace Roots.)

### Blind Spots
- **Interaction with C11-194:** C11-194 introduces a "Workspace Root" which takes precedence over the inherited surface cwd. If the Workspace Root points to a worktree, does this guard block it? Is a Workspace Root considered "inherited" or "explicit"? This plan is entirely blind to its sibling ticket.
- **Timeout and Fallback:** What happens if the `git` command takes 5 seconds to run? Is there a timeout? If it times out or errors, does the launch proceed or abort? The plan has no failure mode design for the probe itself.
- **The Shell Alias Problem:** Many operators alias tools. If someone has an alias `alias agent="c11 launch-agent --cwd ."`, this guard is permanently bypassed because it looks explicit.

### Challenged Decisions
- **Decision:** Use a `git` subprocess probe.
  - *Counterargument:* Reading the `.git` node directly from the filesystem (checking if it's a file containing `gitdir:`) is instantaneous and has zero subprocess overhead. To disambiguate from submodules, you can read the target path and check if it contains `/worktrees/`. This is slightly more fragile but vastly faster and safer than a subprocess. Is the subprocess overhead worth the correctness?
- **Decision:** Blocking launch entirely for inherited worktrees.
  - *Counterargument:* c11's philosophy is "unopinionated about the terminal" and "host and primitive". Injecting opinionated Git-workflow guards into the core launch primitive violates this. A better alternative might be a warning, or handling this entirely client-side in the `lattice-orchestrator` skill rather than the c11 core binary.

### Hindsight Preview
- Two years from now, we will regret adding git-specific guardrails into the core multiplexer. We'll find that users complain about "c11 being slow to launch agents in my huge monorepo" because `git rev-parse` is doing unexpected work, or "c11 refuses to launch in my perfectly valid git setup."
- We'll realize that as the Lattice workflow evolves, the definition of a "dangerous" directory changes, and baking this into compiled Swift code rather than the Skill layer was a mistake.

### Reality Stress Test
1. **C11-194 merges first:** The cwd resolution seam is entirely rewritten to prioritize Workspace Root. This plan's target code no longer exists in the expected shape.
2. **User launches inside a submodule:** The probe incorrectly flags the submodule as a worktree (if implemented naively) and blocks the launch, breaking standard development workflows.
3. **The filesystem is slow:** `git rev-parse` takes 2 seconds to traverse up a deep directory tree. Every agent launch now has a visible, annoying delay, violating the "fast, fluid, effective" mission.

### The Uncomfortable Truths
- We are violating our own "unopinionated about the terminal" principle. We are hardcoding a Lattice-specific workflow guard into the general-purpose `c11` binary.
- This belongs in the `lattice-orchestrator` skill, not the `c11` core. The core should just do what it's told (launch the agent). The orchestrator should be the one ensuring it doesn't cross-contaminate worktrees.
- We are assuming `git` is a fast, safe oracle, which is a classic rookie mistake in systems programming.

### Hard Questions for the Plan Author
1. How exactly will the server differentiate an "inherited" CWD from an "explicit" `--cwd` if the CLI parses and sends an absolute path over the socket?
2. Does the `git rev-parse` probe spawn a subprocess? If so, what is the timeout, and is it on the main thread?
3. What is the explicit fallback behavior if the `git` command fails (e.g., `git` not installed, corrupted repository, permissions error)? Does the launch proceed or abort?
4. C11-194 introduces Workspace Roots. If a Workspace Root resolves to a linked worktree, will this guard block the launch, and should it?
5. Submodules also use a `.git` file. How will your test suite definitively prove that launching inside a submodule is not accidentally blocked?
6. Why is this Git-specific workflow logic going into the `c11` core instead of being a check performed by the `lattice-orchestrator` skill before it issues the launch command?
