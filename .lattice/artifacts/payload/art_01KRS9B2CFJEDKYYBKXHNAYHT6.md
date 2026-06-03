### 1. Verdict

**FAIL (plan-level)** — Plan has significant gaps or issues that need to be addressed before implementation. The task should return to `in_planning` for revision.

### 2. Summary

I reviewed the C11-14 plan for adding a configurable default terminal agent to new terminal surfaces. The plan is well decomposed and captures much of the desired operator-facing behavior, but it leaves several launch-path details underspecified that could produce broken agent startup or regress existing remote/new-terminal behavior. The biggest concerns are unsafe/incorrect initial prompt delivery for interactive TUIs, lack of integration with the existing Agent Launcher setting, and an unresolved conflict with the current remote terminal startup command path.

### 3. Issues

**[MAJOR] Resolution function / command builder — Initial prompt delivery is incorrect for Codex and fragile for interactive agents**
The plan says to append the initial prompt via shell stdin, including `<<< 'prompt'`, and says Codex receives the initial prompt as stdin. The project instructions explicitly state that Codex ignores piped stdin and should be launched interactively, then sent a file-reference prompt after the TUI is ready. Shell heredocs/stdin are also brittle for multiline prompts, quotes, and markdown, and may not match how other interactive TUIs consume startup input.
**Recommendation:** Split "agent process launch" from "post-launch prompt injection." Launch the configured TUI normally, then deliver the configured initial prompt through the same queued `sendText`/ready-flush path used by the existing agent launcher or via a temp-file reference for Codex. Define per-agent prompt delivery behavior and add tests for escaping/newlines at the resolver or command-builder seam.

**[MAJOR] Architecture / settings — Plan does not reconcile the existing Agent Launcher Button setting**
c11 already has `AgentLauncherSettings` in `c11App.swift` and `Workspace.launchAgentSurface(inPane:)`, with a settings section for the pane tab-bar "A" button. The plan introduces a separate `DefaultAgentConfigStore` and settings page without saying whether the existing Agent Launcher setting is migrated, reused, deprecated, or kept as a separate concept. That creates two competing agent defaults in the UI: one for "A" and one for "New terminal."
**Recommendation:** Add an explicit migration/integration step. Prefer extending the existing agent launcher model into the richer default-terminal-agent config, or clearly define the distinction in product terms and UI. Include migration behavior for `agentLauncherKind`, menu/button semantics after the change, and tests for default values.

**[MAJOR] Workspace plumbing — Remote terminal startup behavior is not covered**
New terminal panels currently derive `initialCommand` from `Workspace.remoteTerminalStartupCommand()`. The plan says to replace `remoteTerminalStartupCommand` when an agent override is present, but it does not define precedence for remote-configured workspaces. Blindly replacing that command could break remote terminal sessions by bypassing the remote relay startup path.
**Recommendation:** Define remote workspace behavior before implementation. Either default-agent launch is bypassed when `remoteConfiguration.terminalStartupCommand` is active, or the agent command is composed as a remote-side command after the relay/session is ready. Add this to the precedence rules and include at least one resolver/plumbing test or documented validation case.

**[MAJOR] CLI flags — `--agent default` semantics conflict with the "bash fallback" requirement**
The plan says `--agent=default` uses the precedence chain's resolved non-bash config and errors if precedence resolves to bash. That is surprising because the task states that when no default is set, new terminal falls back to bash. It also means the only supported `--agent` value can fail in the common "no default configured" state, while named presets are explicitly deferred.
**Recommendation:** Make the CLI contract explicit and user-centered. Either have `--agent default` mean "use the configured default, or bash if none," matching normal new-terminal behavior, or reserve `--agent` until named presets exist and only implement `--bash` in the first PR. If an error is desired, define the exact error message and acceptance criterion.

**[MINOR] Data model / command construction — Argument parsing and escaping rules are underspecified**
The plan stores model, extra args, custom command, and initial prompt as free text and builds a command string. That leaves shell quoting, environment expansion, malformed args, and injection-like accidental command composition undefined. This matters because examples include markdown prompts and permission flags, and c11 will run these commands automatically.
**Recommendation:** Define a small command-rendering policy: which fields are tokenized, which are shell-expanded, and how values are escaped. If the Ghostty API only accepts a command string, centralize shell-quoting and test spaces, quotes, empty fields, and multiline prompt cases.

**[MINOR] Acceptance criteria / docs — Operator-facing verification and documentation are incomplete**
The plan mentions documenting per-workspace metadata in skill/release notes, but the file-level change list does not include the c11 skill or user-facing docs. Because this changes the meaning of "New terminal" and adds "New bash terminal," agents and operators need the CLI/UI contract updated alongside code.
**Recommendation:** Add `skills/c11/SKILL.md` or the appropriate source skill file to the change list, with examples for `new-surface`, `new-split`, `--bash`, `--agent`, and workspace metadata overrides. Include verification steps for UI menu behavior and CLI behavior.

### 4. Positive Observations

The plan has a strong first-PR scope boundary: single default config, named presets deferred, per-workspace UI deferred, and external TUI config writes explicitly rejected.

The precedence chain is mostly clear and testable, and the plan correctly emphasizes logic-only tests through the `c11-logic` scheme rather than local host-app tests.

The file-level change list and implementation order are practical. Starting with the model/resolver before UI and socket plumbing should reduce rework once the unresolved launch semantics are clarified.
