# Merged Plan Review: C11-14 — Default terminal agent

## 1. Verdict

**FAIL (plan-level)** — the plan body and the v1-response section describe materially different features, and the project-config feature lands a new repo-to-shell execution path without a trust model. Reconcile the plan into one coherent contract (and decide the trust posture for `.c11/agents.json`) before the PR moves forward; implementation has substantially landed and is mostly the right shape, so the gap is documentation + a focused security question, not a rewrite.

## 2. Synthesis

Two reviewers (claude, codex) returned; gemini failed. Both agree the plan is directionally strong — clear data model, pure resolver, documented precedence chain, good localization/test discipline — and both identify the same root cause of confusion: the plan body still describes the *original* design (here-string-fed `initialPrompt`, `--agent <name>` CLI flag, `workspace.default_agent_inline`) while the "Plan-review v1 response" section quietly records that those decisions were reversed. Where the reviewers diverge is on severity: claude treats the body/response drift as a documentation cleanup against an implementation that has substantially landed (PASS with several documentation fixes), while codex treats the same inconsistencies as a contract-defining ambiguity that should send the work back to planning (FAIL). Codex additionally surfaces a critical issue that claude missed: `.c11/agents.json` with `customCommand`/`extraArgs`/env overrides means opening a terminal in an untrusted checkout could auto-execute project-provided shell text, and no trust boundary is specified. That single finding tips the merged verdict toward FAIL (plan-level): even with implementation landed, the trust model needs an explicit decision before this is operator-facing.

## 3. Issues

### [CRITICAL] Project-local `.c11/agents.json` is a new repo-to-shell execution path with no trust boundary
*(codex)*

The plan adds project-precedence `.c11/agents.json` that can carry `customCommand`, `extraArgs`, env overrides, and a fixed cwd. Because new terminals auto-launch the resolved config, `cd` into an untrusted checkout → new terminal → arbitrary project-provided shell text executes. The risk register does not cover this. The current implementation appears to honor project config without prompting; that needs to be a deliberate choice, not a default.

**Recommendation:** Land a trust model before this PR merges. Options (pick one, document the choice):
- Disable project config by default; require explicit per-project approval (one-time prompt; record consent in a c11-owned trust store, *not* in the project repo).
- Honor project config only for known agent types and *non-command* fields (model, extraArgs subset, env); ignore `customCommand` from project files entirely.
- Require workspace-level trust (the workspace must already be opted into project config; new workspaces start untrusted).

Add tests for the untrusted/malformed/project-override paths and document the chosen behavior in the plan body and the user-visible Settings copy.

### [CRITICAL / MAJOR] Plan body and v1-response describe two different launch contracts
*(both reviewers — codex CRITICAL, claude MAJOR)*

The plan body (data-model docs, command-builder bullets, per-type prose) describes `initialPrompt` as piped via `<<<` shell here-string and the launch happening through Ghostty's `initialCommand` startup hook. The v1-response section records what actually shipped: a login shell starts first, then `TerminalPanel.sendText(...)` types one launch command post-ready; only claude-code receives `initialPrompt` (appended as a single-quoted positional arg); codex/kimi/opencode preserve the field but do not auto-append. This determines whether interactive TUIs work, whether the shell survives the agent exiting, and where quoting rules live. A reader of the body alone forms the wrong mental model.

**Recommendation:** Rewrite the design section around the one shipped contract:
- Terminal starts a login shell.
- c11 sends one shell command after surface ready via `sendText` (cite `AgentLauncherSettings.launchAgentSurface` + welcome workspace as precedent).
- Per-agent `initialPrompt` policy: claude-code → positional arg; codex/kimi/opencode → preserved-in-config, not auto-appended (operator can use `extraArgs` for prompt delivery on those TUIs); cite codex's stdin-ignoring constraint inline.
- Tests assert the exact generated shell string (this already exists in `DefaultAgentResolverTests`; reference the test names in the plan body).

### [MAJOR] `--agent <name>` is both in-scope and dropped
*(both reviewers)*

Proposal, Scope, CLI flags section, and Implementation order step 2 all describe `--agent <name>` parsing on `new-split` / `new-pane` / `new-surface`. The v1 response says only `--bash` is wired and `--agent` is deferred to the named-presets follow-up. The resolver still takes `explicitAgent: String?` with no CLI surface populating it. Acceptance criteria and PR ownership are unclear.

**Recommendation:** Pick one for *this* PR and propagate consistently. Recommended path (matches what shipped): defer `--agent`. Then:
- Remove `--agent` from In-Scope, CLI flag plumbing, tests, and Implementation order.
- Add one line under Deferred / Out-of-Scope: "`--agent <name>` reserved for the named-presets follow-up; resolver retains `explicitAgent: String?` to make that PR small."

### [MAJOR] Per-workspace override is narrower than the proposal claims
*(both reviewers)*

Scope says per-workspace override is in-scope; the proposal describes workspaces that can be "claude" or "shell" workspaces. The v1-response drops `workspace.default_agent_inline` and keeps only `workspace.default_agent_use_bash` (and the shipped key is `default_agent_use_bash` with no `workspace.` prefix). A workspace can force bash but cannot override to a different agent config — a narrower feature than the task/proposal describes. The Per-workspace override section and the Resolution-function section still use the old key names.

**Recommendation:** Either restore real per-workspace agent override for this PR or revise the scope honestly:
- If narrowing: rename the section "Per-workspace bash opt-out", normalize the key to `default_agent_use_bash` everywhere in the plan, and add a deferred-work line for "full per-workspace agent config (likely via `.c11/blueprints/`-style file)".
- Pick the metadata key name and value type *once* and use it consistently.

### [MAJOR] Settings persistence has no validation or error surface
*(codex)*

Settings persists free-form model, args, command, cwd, and env rows on every change. Plan does not define what happens for invalid env keys, blank `customCommand` when agent type is custom, malformed project JSON, invalid fixed cwd, or UserDefaults write failures. These fields directly shape the shell command; bad state can make every new terminal fail.

**Recommendation:** Add validation + visible error states to the plan:
- Reject invalid env keys at the row.
- Require `customCommand` non-empty when agent type is custom; show inline validation.
- Treat blank fixed cwd as "inherit".
- Surface project-config parse errors somewhere inspectable (Settings card warning row, debug log entry, or both).
- Provide a one-click "reset to bash" affordance for recovery.

### [MAJOR] `agentOverride: nil` is overloaded
*(codex)*

`Workspace.newTerminalSurface(...)` takes `agentOverride: ResolvedAgent?`. Bash resolution is represented as `ResolvedAgent(command: nil, ...)`; no-override is `nil`. "Force bash" and "use current behavior" are different states but share representations across menu, CLI, and workspace paths — easy to miswire.

**Recommendation:** Model the decision as an explicit enum, e.g. `enum LaunchDecision { case legacy; case bash; case agent(ResolvedAgent) }`. Or alternatively, resolve at every call site so `Workspace` never sees `nil` for a resolved bash decision. Add focused coverage for default-bash, forced-bash, and no-config behavior on the workspace surface.

### [MINOR] CLI and menu paths under-specified for acceptance
*(codex; partially overlaps claude #9)*

Logic tests cover resolver/command-builder, but CLI parsing, "New Bash Terminal" menu item, and `sendText` launch timing are deferred to build/manual/CI. These are the highest-risk integration paths.

**Recommendation:** Add a compact Acceptance subsection mapping each operator-visible requirement to its verification:
- "New Terminal" launches configured agent → tagged-build manual + Settings UI smoke.
- "New Bash Terminal" stays bash → menu item present + tagged-build smoke.
- `--bash` bypasses defaults → CLI test (logic) + manual confirmation.
- Malformed `.c11/agents.json` falls back safely → resolver test (logic).
- Remote relay runs before agent launch → manual confirmation in remote workspace.

### [MINOR] No test coverage for `kimi` / `opencode` command builder
*(claude)*

The plan claims "Command builder: covers each agent type." Tests cover claude-code, codex, and custom; kimi/opencode are trivially "binary name" but the enum-dispatch coverage costs nothing.

**Recommendation:** Add `testBuildCommandKimi` and `testBuildCommandOpencode` (one assertion each, mirroring `testBuildCommandCodexNoModel`).

### [MINOR] `Workspace.resolveAgentForNewSurface(...)` integration wrapper untested
*(claude)*

The pure resolver is well-tested; the Workspace-level wrapper that reads `DefaultAgentConfigStore.shared`, walks `.c11/agents.json`, and translates `metadata["default_agent_use_bash"]` lives in a host-only file and is implicitly deferred to CI.

**Recommendation:** Either (a) hoist the metadata→`WorkspaceAgentOverride` translation into a free function in a logic-eligible file and add a test, or (b) add a one-line risk-register note that this wrapper is intentionally not covered by `c11-logic` and is validated via CI + manual smoke.

### [MINOR] `--bash` × `--type=browser` interaction undocumented
*(claude)*

Implementation correctly skips agent resolution when `panelType == .browser`. Correct, but unrecorded; a future reader could reasonably wonder.

**Recommendation:** One line in the CLI flags section: "`--bash` is a no-op when combined with `--type=browser`; only terminal surfaces consult the resolver."

### [MINOR] Settings changes don't affect already-open terminals; not stated
*(claude)*

Natural and expected (resolver consults at new-terminal time), but the Settings UI section and the localized card note don't say so. Operator who changes model from `claude-sonnet-4-6` → `claude-opus-4-7` and expects their existing claude pane to migrate will be surprised.

**Recommendation:** One-line clarification in the Settings UI section: "Changes apply to subsequent new-terminal creations only; in-flight terminals are not relaunched." Mirror briefly in the Settings card's localized note if practical.

### [MINOR] `sendText` queue-and-flush invariant not in the risk register
*(claude)*

Post-ready `sendText` relies on `TerminalPanel` queuing input until ready, then flushing. If that queuing regresses, the agent command silently won't fire.

**Recommendation:** One-line risk-register entry pointing at the queuing dependency and noting precedent paths (welcome workspace + `AgentLauncherSettings.launchAgentSurface`) that share the same fate.

### [MINOR] pbxproj diff bloat warning missing from risk register
*(claude)*

`scripts/c11-14-register-files.rb` will produce a multi-thousand-line diff (per the CLAUDE.md pitfall on `xcodeproj` gem normalization). Reviewers should be primed.

**Recommendation:** One-line risk-register entry: "pbxproj diff will be large due to xcodeproj gem normalization; gate on `xcodebuild -list` + `c11-logic` test pass + file-membership counts, not line-by-line diff review."

### [MINOR] Acceptance-criteria checklist is implicit, not explicit
*(claude; overlaps codex acceptance recommendation above)*

The task has two concrete operator-visible requirements; both are addressed but there's no compact verification checklist mapping task requirement → plan section → test/manual step.

**Recommendation:** Add a 4-6-line "Acceptance" subsection at the bottom of the plan (subsumes the codex acceptance recommendation).

## 4. Positive Observations

- **Good decomposition.** Both reviewers note the plan cleanly separates model, resolver, project discovery, CLI plumbing, workspace plumbing, settings UI, localization, and tests.
- **Respects the c11 boundary.** Both flagged this: no `c11 install <tui>`, no persistent writes to tenant config — the design stays within c11's own runtime.
- **Right repo-specific constraints surfaced.** `c11-logic` for local tests, no host test runs, no typing-latency hot paths touched, localization at the call site — all called out and held.
- **The launch-mechanism reshape was the correct call.** Switching from Ghostty `initialCommand` to post-ready `sendText` is what makes interactive TUIs behave (operator's login shell stays alive, quitting the agent returns to shell). The v1-review caught this and the response section records the reasoning — that reasoning just needs to be folded into the plan body.
- **Precedence chain is well-thought-through and tested.** Nine precedence tests covering force-bash, explicit-agent acceptance/rejection/case-insensitivity, workspace use-bash, workspace inline, project, user default, and bash-agent-type fallthrough.
- **Lenient `DefaultAgentConfig` decoder.** Missing fields fall back to defaults, malformed `agentType` resolves to bash. Hand-edited `.c11/agents.json` can't brick new-terminal flow (separate from the trust question above).
- **Project-config walk is bounded.** 64-level cap matches `WorkspaceBlueprintStore` discipline.
- **Working-directory and env precedence explicit at the resolver boundary.** Caller-supplied `workingDirectory` wins over agent override; `startupEnvironment` layers on top of agent env.
- **Localization discipline intact.** All new English strings via `String(localized:)`; 24-string xcstrings sync ran in a separate commit (`c62c17cde`).
- **Out-of-scope section is honest.** Multiple named presets, sub-agent lineage composition, per-workspace UI, and `c11 install <tui>` all explicitly deferred with reasons.
- **Risk register names typing-latency hot paths.** `WindowTerminalHostView.hitTest`, `TabItemView`, `TerminalSurface.forceRefresh` confirmed not touched — the right pre-implementation sanity check for this codebase.
- **Branch hygiene.** Starting fresh on `c11-14/default-terminal-agent` from `main` (after spotting the misprefixed `c11-14/phase-1-followup` and `c11-14/stage-3-full-primitive` CMUX-37 leftovers) prevents archaeological confusion.

## 5. Reviewer Agreement

**Agreed (both reviewers):**
- Plan body and v1-response section describe materially different launch contracts; needs reconciliation.
- `--agent <name>` flag is contradictorily in-scope and dropped.
- Per-workspace override narrowed from "agent override" to "bash opt-out only" without revising the proposal.
- The plan is directionally strong, well-decomposed, and respects c11 boundaries.
- Repo-specific constraints (c11-logic, no host tests, typing-latency, localization) correctly surfaced.

**Disagreed:**
- **Severity / verdict.** Claude → PASS, treating the inconsistencies as documentation drift against a substantially-landed implementation. Codex → FAIL (plan-level), treating the same inconsistencies as contract-defining ambiguity that should send the work back to planning.
- **Surface area.** Claude's review is broader (eight minor items on documentation, coverage gaps, risk-register hygiene). Codex's review is narrower and heavier on contract-shape and security issues.

**Unique to codex (and the deciding factor for the merged FAIL):**
- `.c11/agents.json` as a new repo-to-shell execution path without a trust boundary. This is the single most consequential finding across both reviews and is unaddressed in the plan.
- `agentOverride: nil` overloading "force-bash" and "no-override" into one representation.
- Settings persistence missing validation/error surface.

**Unique to claude:**
- Eight minor items around plan-body drift, test coverage for kimi/opencode, workspace integration wrapper coverage, `--bash` × `--type=browser` doc, in-flight terminals not migrating, `sendText` queue invariant in risk register, pbxproj diff-bloat note, explicit acceptance checklist.

**Gemini:** failed/timed out — no input.
