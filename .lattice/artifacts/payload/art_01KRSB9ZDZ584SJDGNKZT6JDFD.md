### 1. Verdict

**FAIL (plan-level)**

### 2. Summary

Reviewed the C11-14 default-terminal-agent plan against the task description, proposal, and c11 project constraints. The plan is directionally strong and identifies many of the right code areas, but it is internally inconsistent on several behaviors that define the feature contract. Implementation should return to planning long enough to reconcile launch semantics, CLI scope, workspace overrides, and the security model for project-local configs.

### 3. Issues

**[CRITICAL] Design / Plan-review v1 response - Launch mechanism is contradictory**
The main design still specifies building commands with here-strings and feeding `initialPrompt` through shell stdin, while the later response says the implementation was reshaped to open a login shell first and then type the launch command via `sendText`, with no here-string and only claude-code receiving `initialPrompt` as an argument. This is not a detail: it determines whether interactive TUIs behave correctly, whether the login shell remains after exit, how prompts are delivered, and where quoting rules apply.
**Recommendation:** Rewrite the design section around a single launch contract. State explicitly: terminal starts a login shell, c11 sends one shell command after surface creation, `initialPrompt` delivery is supported only for the agents with documented safe semantics, and tests cover the exact generated shell string.

**[CRITICAL] Data model / Project config - Project-local config can auto-run arbitrary commands without a trust boundary**
The plan adds `.c11/agents.json` with project precedence over user settings, including `customCommand`, `extraArgs`, env overrides, and fixed cwd. Because new terminals would auto-launch the resolved config, opening a terminal in an untrusted checkout could execute arbitrary project-provided shell text. That is a new repo-to-shell execution path and is not covered by the risk register.
**Recommendation:** Add a trust model before implementation. Options include disabling project config by default, requiring explicit workspace trust or per-project approval, ignoring `customCommand` from project files, or limiting project overrides to known agent types and non-command fields. Document the chosen behavior and add tests for untrusted/malformed/project override cases.

**[MAJOR] Scope / CLI flags - `--agent` is both in scope and dropped**
The scope and CLI sections say `new-split`, `new-pane`, and `new-surface` get `--agent <name>` plus `--bash`. The later response says `--agent` was dropped from the first PR and only `--bash` is wired. That leaves acceptance criteria and implementation ownership unclear, especially because the resolver still accepts `explicitAgent`.
**Recommendation:** Choose one first-PR behavior and update every section consistently. If `--agent` is deferred, remove it from "In scope", CLI flag plumbing, tests, and implementation order, then list it under deferred work. If it stays, define supported values and error behavior.

**[MAJOR] Scope / Per-workspace override - Workspace override no longer satisfies the stated requirement**
The plan's scope says per-workspace override is in scope, and the proposal describes workspaces that can be "claude" or "shell" workspaces. The follow-up notes drop `workspace.default_agent_inline` and keep only `workspace.default_agent_use_bash`, which means a workspace can force bash but cannot override to a different agent config. That is a narrower feature than the task/proposal describes.
**Recommendation:** Either restore a real per-workspace agent override for this PR or revise the scope to "per-workspace bash opt-out only" and defer full workspace-specific agent config. The plan should also specify the exact metadata key name and value type once, since it currently uses multiple names.

**[MAJOR] Workspace plumbing / `agentOverride` semantics - `nil` is overloaded**
The plan says `Workspace.newTerminalSurface(...)` accepts `agentOverride: ResolvedAgent?`; non-nil replaces startup behavior and nil uses current behavior. But bash resolution is represented as `ResolvedAgent(command: nil, ...)`, while no override is represented as nil. This is easy to miswire across menu, CLI, and workspace paths because "force bash" and "use old behavior" are separate states.
**Recommendation:** Model the launch decision as an explicit enum, for example `.legacy`, `.bash`, `.agent(ResolvedAgent)`, or ensure every call path resolves before reaching `Workspace` and never uses nil to mean a resolved bash decision. Add tests or focused coverage for default bash, forced bash, and no-config behavior.

**[MAJOR] Settings UI / Persistence - Save-on-change lacks validation and error handling**
The settings plan persists free-form model, args, command, cwd, and env rows on every change. It does not define validation for env keys, missing custom command, invalid fixed cwd, malformed project JSON, or failures writing UserDefaults. Since these fields directly shape shell commands, bad state could make every new terminal fail.
**Recommendation:** Add validation rules and user-visible error states to the plan. At minimum: reject invalid env keys, require `customCommand` for custom agent, treat blank fixed cwd as inherit, show project-config parse errors somewhere inspectable, and provide a way to reset to bash.

**[MINOR] Tests / Acceptance coverage - CLI and menu behavior are under-specified for verification**
The logic tests cover resolver and command builder behavior, but the plan leaves CLI parsing, menu "New Bash Terminal", and `sendText` launch timing to build/manual/CI validation without concrete acceptance checks. These are the highest-risk integration paths.
**Recommendation:** Add explicit acceptance criteria for each user-visible path: default "New Terminal" launches configured agent, "New Bash Terminal" stays bash, `--bash` bypasses defaults, malformed config falls back safely, and remote relay runs before agent launch. If automated UI tests are impractical, name the tagged-build manual checks and expected observable results.

### 4. Positive Observations

The plan is well decomposed into model, resolver, project discovery, CLI plumbing, workspace plumbing, settings UI, localization, and tests. It correctly respects the c11 boundary by avoiding `c11 install <tui>` and persistent edits to external TUI configs.

The plan also identifies important repo-specific constraints: use `c11-logic` locally, avoid host test runs, avoid typing-latency hot paths, and localize new strings. The prior review response shows useful learning from the interactive TUI launch problem; that learning just needs to be folded back into a single coherent plan before implementation proceeds.
