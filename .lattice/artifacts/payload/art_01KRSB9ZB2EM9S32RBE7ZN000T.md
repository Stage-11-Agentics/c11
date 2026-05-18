# Plan Review: C11-14 — Default terminal agent

## 1. Verdict

**PASS** — with several documentation/coverage fixes recommended (none blocking).

## 2. Summary

Reviewed the C11-14 plan (`Default terminal agent: launch a configured agent on new-terminal`) after the v1 plan-review iteration. The plan is well-scoped, with a clear data model, a pure resolver, a 7-rule precedence chain, a documented file-level change list, an implementation order, and a risk register. The v1 response section transparently records that the launch mechanism was reshaped from Ghostty's `initialCommand` startup hook to a post-ready `TerminalPanel.sendText(...)` typed-line — the correct call for interactive TUIs, matching the existing `AgentLauncherSettings.launchAgentSurface` pattern. The principal concern is **documentation drift between the plan body (still describes the original design) and the "Plan-review v1 response" section (records what actually shipped)**: a reviewer reading the body alone would form an incorrect mental model of the current implementation. Implementation has substantially landed on `c11-14/default-terminal-agent`; sampled code matches the v1-response shape (not the body shape).

## 3. Issues

**[MAJOR] Plan body — `--agent <name>` flag is still documented but was dropped from the PR**
The Proposal (line 33), Scope/in-scope (line 59), CLI flags section (lines 152-159), and Implementation order step 2 (line 230) all describe `--agent <name>` parsing on `new-split` / `new-pane` / `new-surface`. The v1 response section (line 266) records that `--agent` was dropped from this PR and that only `--bash` is wired; the resolver still accepts `explicitAgent: String?` for the named-presets follow-up but no CLI surface populates it. The actual implementation in `Sources/TerminalController.swift` confirms only `--bash` is parsed. Leaving both stories in the same document will confuse code reviewers and future readers.
**Recommendation:** Edit the Proposal, Scope, and "CLI flags" sections so the body matches the v1 response: `--bash` only on `new-split` / `new-pane` / `new-surface`, with a single sentence noting `--agent <name>` is reserved for the named-presets follow-up. Update Implementation order step 2 accordingly.

**[MAJOR] Plan body — `workspace.use_bash` / `workspace.default_agent_inline` metadata keys don't match the shipped key**
The Resolution function section (lines 137-138) lists `workspace.use_bash` and `workspace.default_agent_inline` as the workspace metadata keys. The v1 response section (line 268) records that `default_agent_inline` was dropped and only `default_agent_use_bash` is recognized. The actual implementation uses `default_agent_use_bash` (no `workspace.` prefix). The Per-workspace override section (lines 187-190) repeats the wrong key names. A maintainer following the plan to write release-note copy or to extend the override would set the wrong metadata key.
**Recommendation:** In the precedence list, the Per-workspace override section, and Out-of-scope, rename `workspace.use_bash` → `default_agent_use_bash`, drop the `default_agent_inline` line, and note that an inline-config override is deferred to a future ticket (likely via `.c11/blueprints/`-style file rather than a metadata blob).

**[MAJOR] Initial-prompt delivery contract changed; plan body still describes `<<<` here-string for all agents**
Data model docs (lines 96-98), command-builder bullets (lines 144-147), and the per-type prose all describe `initialPrompt` as "piped via `<<<` if non-empty". The v1 response section (line 260) records the actual decision: claude-code appends the prompt as a single-quoted positional argument; other agents preserve the field in config but do **not** auto-append. Tests confirm this (`testBuildCommandClaudeWithInitialPromptAppendsPositional`, `testBuildCommandCodexIgnoresInitialPrompt`). This is the most operator-visible behavior change; the plan body undersells it.
**Recommendation:** Rewrite the `initialPrompt` field doc and the command-builder bullets to describe the per-agent policy explicitly (claude-code → positional arg; others → preserved-in-config, not auto-appended; operator can use `extraArgs` for prompt delivery on other TUIs). Cite the codex stdin-ignoring constraint inline.

**[MINOR] Test coverage gap — `kimi` and `opencode` agent types not exercised in the command builder**
The plan (line 205) says "Command builder: covers each agent type". Tests in `DefaultAgentResolverTests.swift` cover claude-code, codex, and custom. `kimi` and `opencode` produce trivially the binary name in the resolver, but adding a one-line test each costs nothing and proves the enum dispatch is hooked up.
**Recommendation:** Add `testBuildCommandKimi` and `testBuildCommandOpencode` (single assertion each, mirroring `testBuildCommandCodexNoModel`).

**[MINOR] No coverage for the `Workspace.resolveAgentForNewSurface(...)` integration wrapper**
The pure `DefaultAgentResolver` is well-tested. The Workspace-level wrapper that (a) reads `DefaultAgentConfigStore.shared`, (b) walks `.c11/agents.json`, and (c) translates `metadata["default_agent_use_bash"]` into `WorkspaceAgentOverride` is untested — it lives in `Workspace.swift` (a host-only file) and is therefore implicitly deferred to CI's `c11-unit` scheme. That's defensible per the plan's "UI/event-path code via xcodebuild build + tagged-reload + CI" policy, but the wrapper isn't UI — it's translation logic that could be exercised under the logic scheme if hoisted into a small helper (e.g. `WorkspaceAgentMetadata.use_bash(from: [String: String]) -> Bool`).
**Recommendation:** Either (a) hoist the metadata→`WorkspaceAgentOverride` translation into a free function in a logic-eligible file and add a test, or (b) add a one-line risk-register note that this wrapper is intentionally not covered by `c11-logic` and is validated via CI + manual smoke (operator sets the metadata key, opens a terminal, sees bash).

**[MINOR] Plan does not record the `--bash` × `--type=browser` interaction**
For both `newPane` and `newSurface`, the implementation correctly skips agent resolution when `panelType == .browser` (browsers don't have shell agents). This is the right behavior, but it's not documented in the plan — a future reader could reasonably wonder whether `--bash` is ignored, errored, or applied somehow when combined with `--type=browser`.
**Recommendation:** One-line in the CLI flags section: "`--bash` is a no-op when combined with `--type=browser`; only terminal surfaces consult the resolver."

**[MINOR] Settings change does not affect already-open terminals; plan doesn't say so**
This is the natural and expected behavior (the resolver is consulted at new-terminal time), but the Settings UI section (lines 169-180) doesn't call it out and the Settings card's localized note doesn't either. An operator who changes the model from `claude-sonnet-4-6` → `claude-opus-4-7` and expects their existing claude pane to migrate will be surprised.
**Recommendation:** Add a one-line clarification to the Settings UI section: "Changes apply to subsequent new-terminal creations only; in-flight terminals are not relaunched." If practical, mirror that in the localized note on the Settings card.

**[MINOR] No `sendText` queue-and-flush invariant in the risk register**
The post-ready `sendText` pattern relies on `TerminalPanel` queuing input until the surface is ready, then flushing. The implementation comments cite the welcome-workspace + `AgentLauncherSettings.launchAgentSurface` precedent. If that queuing invariant ever regresses (e.g. via a refactor that drops pre-ready writes), the agent command silently won't fire. The risk register doesn't mention it.
**Recommendation:** Add a one-line entry to the risk register pointing at the queuing dependency and noting the precedent paths (welcome workspace + `AgentLauncherSettings.launchAgentSurface`) that share the same fate if it regresses.

**[MINOR] `scripts/c11-14-register-files.rb` is in the change list but not in the risk register**
Per the CLAUDE.md pitfall on pbxproj edits via the `xcodeproj` Ruby gem ("a 'small' semantic edit can produce a multi-thousand-line diff"), reviewers should be primed for the diff bloat and told the right gate (`xcodebuild -list` + file-membership counts + `c11-logic` test pass).
**Recommendation:** Add a one-line risk-register entry: "pbxproj diff will be large due to xcodeproj gem normalization; gate on `xcodebuild -list` + `c11-logic` test pass, not line-by-line diff review."

**[MINOR] Acceptance-criteria checklist is implicit, not explicit**
The task description has two concrete user-visible requirements: (1) "configure a default terminal agent for new terminal surfaces" and (2) "bash experience is still available via an explicit 'new bash terminal' action." Both are addressed in the plan, but there's no compact verification checklist mapping task requirement → plan section → test/manual step. This is fine for a singleton ticket but makes PR-review and code-review's job harder.
**Recommendation:** Add a 4-6-line "Acceptance" subsection at the bottom of the plan listing each operator-visible criterion and where it's covered (Settings UI for #1; "New Bash Terminal" menu item + `--bash` CLI flag for #2; localization for both).

## 4. Positive Observations

- **The launch-mechanism reshape is the right call.** Switching from Ghostty `initialCommand` startup hook to post-ready `sendText` is what makes the feature work for interactive TUIs — operator's login shell stays alive, quitting the agent returns to the shell, and the pattern matches `AgentLauncherSettings.launchAgentSurface` and the welcome workspace. The plan-review v1 caught this and the response section records the reasoning clearly.
- **Precedence chain is well-thought-through and tested.** Nine precedence tests covering force-bash, explicit-agent acceptance/rejection/case-insensitivity, workspace use-bash, workspace inline, project, user default, and bash-agent-type fallthrough.
- **Lenient `DefaultAgentConfig` decoder.** Missing fields fall back to defaults, malformed `agentType` resolves to bash. Hand-edited `.c11/agents.json` files can't brick the new-terminal flow.
- **Project-config walk is bounded.** 64-level cap prevents a pathological cwd from spinning forever (matches `WorkspaceBlueprintStore` discipline).
- **Working-directory and env precedence are explicit and tested at the resolver boundary.** Caller-supplied `workingDirectory` wins over agent override; `startupEnvironment` layers on top of agent env. The Workspace plumbing comment in the split path documents this clearly.
- **Localization discipline is intact.** All new English strings via `String(localized:)`; the 24-string xcstrings sync ran in a separate commit (`c62c17cde`); the Settings card's distinguishing note for the per-pane "A" launcher is included.
- **Out-of-scope section is honest.** Multiple named presets, sub-agent lineage composition, per-workspace UI, and `c11 install <tui>` are all explicitly deferred with reasons.
- **Risk register names the typing-latency hot paths** (`WindowTerminalHostView.hitTest`, `TabItemView`, `TerminalSurface.forceRefresh`) and confirms none are touched — this is exactly the pre-implementation sanity check this codebase needs.
- **Submodule warning is current and correct.** The `vendor/bonsplit` SHA pinning note about an out-of-sync working tree producing compile errors will save the next agent debugging time.
- **Tests are routed through `c11-logic`.** Adheres to the CLAUDE.md testing policy and the `feedback_no_local_xcodebuild_test` memory; the `scripts/c11-14-register-files.rb` adds the test files to both `c11Tests` and `c11LogicTests` source phases so `xcodebuild -scheme c11-logic test` runs them.
- **Notes on abandoned branches.** Spotting that `c11-14/phase-1-followup` (PR #78) and `c11-14/stage-3-full-primitive` were misprefixed CMUX-37 work, and starting fresh from `main` on a clean `c11-14/default-terminal-agent` branch, is the kind of cleanup that prevents archaeological confusion six months from now.
