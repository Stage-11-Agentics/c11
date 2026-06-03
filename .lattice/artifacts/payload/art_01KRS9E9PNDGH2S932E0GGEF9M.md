# Merged Plan Review: C11-14 — Default Terminal Agent

## 1. Verdict

**FAIL (plan-level)** — Both completing reviewers (claude, codex) independently arrived at FAIL. The plan's shape, scope boundary, and file-seam identification are sound, but the launch-path semantics (initial-prompt delivery, shell quoting, remote-terminal interaction) are underspecified in ways that will produce broken behavior or rework once implementation starts. Return to `in_planning` for a targeted revision pass; the gaps are small and concrete, not architectural.

## 2. Synthesis

Two reviewers converged on the same load-bearing concern from different angles: **the plan describes *what* gets launched but not *how* the agent process actually receives its initial prompt, args, and cwd.** Both flagged the `<<<` herestring mechanism as wrong for interactive TUIs (claude reads it as a closed-stdin footgun; codex notes the project's own docs say Codex ignores piped stdin and must receive prompts after readiness via the queued send path). Both flagged that `extraArgs` / `customCommand` shell-quoting is undefined, and both flagged that the relationship to the existing `remoteTerminalStartupCommand` path is ambiguous (replace? compose? bypass for remote workspaces?). Beyond the overlapping concerns, claude added codebase-specific risks (test-target membership, the missing `newTerminalSurfaceInFocusedPane` call path, cwd disambiguation, metadata-as-JSON-blob awkwardness), and codex surfaced a product-level concern that claude missed: **the plan does not reconcile with the existing `AgentLauncherSettings` / `launchAgentSurface` system,** which would leave two competing "agent default" UIs in the app. Both reviewers praised the in-scope/deferred split, the implementation order, and the file-level change list. The gemini review did not complete and is not represented here.

## 3. Issues

**[CRITICAL] Initial-prompt delivery via `<<<` is wrong for interactive TUIs** *(both reviewers)*
The plan pipes `initialPrompt` through a bash herestring and says codex/kimi/opencode "take initialPrompt as stdin." This is wrong on two grounds. (a) `<<<` closes stdin after delivering the string, which drops interactive TUIs out of readline / interactive mode. (b) The project's own validation notes (CLAUDE.md) say Codex ignores piped stdin and must receive prompts via the queued `sendText` / ready-flush path *after* the TUI is ready — typically as a file-reference prompt for multiline content. There is no universal stdin-prompt convention across claude / codex / kimi / opencode.
**Recommendation:** Split "process launch" from "post-launch prompt injection." Launch the TUI normally with the right launch contract per agent (claude-code: trailing positional arg; codex: interactive then file-reference via existing send path; kimi/opencode: verify per agent), and deliver `initialPrompt` through the existing agent-launcher queued-send mechanism rather than via shell stdin. Add per-agent tests for escaping, newlines, and multiline markdown prompts. Manual-verify each agent type in a tagged build before locking the design.

**[CRITICAL] Test-target placement is ambiguous and load-bearing** *(claude)*
New test files are listed under `c11Tests/DefaultAgentConfigTests.swift` and `c11Tests/DefaultAgentResolverTests.swift` with a "c11-logic only" claim, but directory placement does NOT determine pbxproj target membership. If the files land only in the `c11Tests` (host) target's Sources phase, the "safe to run locally" promise breaks and they end up requiring the host-app launch that crashes the operator's running c11 (per the recent PR #164 incident). The xcodeproj-ruby-gem normalization gotcha makes diff-based review of this fragile.
**Recommendation:** State explicitly that the new files are added to the `c11LogicTests` target's Sources build phase (`37DDE3B0A6A70E75A7B2BEDF`) and NOT to `c11Tests`. Spell out verification: `xcodebuild -scheme c11-logic test` must include the new tests. Consider placing them under `c11Tests/Logic/` to make the intent visually obvious in the file tree.

**[CRITICAL] Shell-quoting of `extraArgs` and `customCommand` is undefined** *(both reviewers)*
The plan says `extraArgs` is "appended as-is" but doesn't pin the underlying execution model: argv array (whitespace-split, quotes literal), shell-string (`/bin/sh -c`, quotes honored), or direct `posix_spawn`. An operator typing `--model "claude opus 4-7" --verbose` gets different behavior in each. Codex flagged this is especially risky because c11 runs the resulting commands automatically and the examples include markdown prompts with permission flags.
**Recommendation:** Pick one execution model and document it. If the existing `initialCommand: String?` on `TerminalPanel` is shell-string-shaped (verify), keep `extraArgs: String` with documented per-shell-token parsing; otherwise switch the data model to `extraArgs: [String]`. Centralize shell-quoting at the resolver boundary. Add a logic test that an extraArgs value of `--model "claude opus 4-7" --verbose` reaches the resolver correctly, plus cases for spaces, embedded quotes, empty fields, and multiline prompts.

**[MAJOR] Plan does not reconcile with existing `AgentLauncherSettings` / `launchAgentSurface`** *(codex)*
c11 already has `AgentLauncherSettings` in `c11App.swift` and `Workspace.launchAgentSurface(inPane:)`, with a settings section for the pane tab-bar "A" button. The plan introduces a separate `DefaultAgentConfigStore` and settings page without reconciling. The result would be two competing "agent default" UIs: one for the "A" button, one for "New Terminal," with different shapes and no migration story.
**Recommendation:** Add an explicit migration/integration step. Preferred: extend the existing agent-launcher model into the richer default-terminal-agent config so there is one canonical "what does an agent surface launch with" setting. If they must remain distinct, define the product-level distinction in UI terms and include migration behavior for `agentLauncherKind` plus tests for the post-change default values.

**[MAJOR] Remote-terminal startup behavior is unresolved** *(both reviewers)*
`Workspace.newTerminalSurface` and `newTerminalSplit` already construct `initialCommand` from `remoteTerminalStartupCommand()` and call `trackRemoteTerminalSurface(...)`. The plan says to "replace `remoteTerminalStartupCommand` when an agent override is non-nil" but doesn't define: (a) what happens in remote-configured workspaces where the relay startup command is load-bearing, (b) whether `trackRemoteTerminalSurface` should fire for agent surfaces (and what regresses if it doesn't), (c) whether agent commands should compose with the relay startup command or be a distinct mode.
**Recommendation:** Add a subsection that nails down: does agent-override REPLACE or COMPOSE with `remoteTerminalStartupCommand`? Is the agent-launch path bypassed entirely when a remote `terminalStartupCommand` is active, or is the agent command composed as a remote-side command after the relay is ready? Should `trackRemoteTerminalSurface` (or an agent-tracking equivalent) fire for these surfaces? Include at least one resolver/plumbing test or a documented manual-validation case for the remote-workspace path.

**[MAJOR] `newTerminalSurfaceInFocusedPane` is missing from the change list** *(claude)*
The menu-driven New Terminal path (`TabManager.newSurface()` at `TabManager.swift:3568`) calls `Workspace.newTerminalSurfaceInFocusedPane(focus:)`, which in turn calls `newTerminalSurface(inPane:focus:)`. The plan threads `agentOverride` through `newTerminalSurface` and `newTerminalSplit` but never `newTerminalSurfaceInFocusedPane`. Without extending that signature, the menu's "New Terminal" item cannot deliver the resolved agent override.
**Recommendation:** Add `Workspace.newTerminalSurfaceInFocusedPane` to the file-level change list. Either thread `agentOverride:` through it, or have `TabManager.newSurface()` resolve the agent once and call `newTerminalSurface(inPane:focus:agentOverride:)` directly with the focused pane id.

**[MAJOR] `--agent=default` semantics conflict with bash fallback** *(both reviewers)*
The plan says `--agent=default` uses the precedence chain's resolved non-bash config and errors if precedence resolves to bash. Codex flagged this conflicts with the task's stated "no default → bash fallback" behavior; claude flagged that with named presets deferred, `--agent` accepts exactly one value and its only added semantic is "force an error" — thin for the cost of introducing the flag.
**Recommendation:** Either (a) drop `--agent` from this PR entirely and ship only `--bash`, deferring the flag until named presets exist, or (b) redefine `--agent default` to mean "use configured default, else bash" (matching normal new-terminal behavior). If the error-on-bash semantic is intentional, define the exact error message and add an acceptance test.

**[MAJOR] Per-project config discovery — "cwd" is underspecified** *(claude)*
"Walk up from cwd looking for `.c11/agents.json`" — but cwd could mean the c11 process's cwd, the focused surface's cwd, the workspace's working directory, or the operator's shell at socket-call time. These differ. The existing `WorkspaceBlueprintStore.perRepoBlueprintURLs(cwd:)` pattern takes cwd explicitly precisely because the answer is non-obvious.
**Recommendation:** Pin the cwd source per call path: (a) menu-driven New Terminal → focused surface's cwd, falling back to workspace working dir, (b) CLI `--agent` via socket → calling shell's cwd (verify whether the existing `new-surface` socket protocol carries cwd; if not, plumb it), (c) split from existing surface → source surface's cwd.

**[MINOR] Argument escaping rules and command-rendering policy not centralized** *(codex; overlaps with shell-quoting CRITICAL above)*
Even after picking an execution model, the resolver should have a single command-rendering policy: which fields are tokenized vs. shell-expanded, how empty fields are handled, how multiline prompts are passed. Examples in the plan include markdown prompts with permission flags, which raises the stakes.
**Recommendation:** Centralize command rendering at a single resolver function with documented inputs/outputs. Logic tests for: empty fields, embedded quotes, spaces in values, multiline prompts, and the markdown-prompt example case.

**[MINOR] JSON-in-a-metadata-string per-workspace override is awkward** *(claude)*
Storing a Codable `DefaultAgentConfig` blob in `workspace.default_agent_inline` fights the existing flat key/value metadata pattern. Setting it via CLI requires shell-escaping JSON; reading requires re-parsing on every lookup; `c11 list-metadata` shows an unreadable blob. `WorkspaceBlueprintStore` already demonstrates the pattern: a file (`.c11/blueprints/<name>.{json,md}`).
**Recommendation:** Two alternatives: (1) per-field metadata keys (`workspace.default_agent.type`, `.model`, `.extra_args`, …) for independent inspect/set, or (2) a per-workspace file like `.c11/workspaces/<id>/agent.json` reusing the `DefaultAgentConfig` codec. Either beats a JSON-in-a-string blob.

**[MINOR] Skill and operator-facing docs missing from change list** *(codex)*
The plan changes the meaning of "New Terminal" and adds "New Bash Terminal," plus `--bash` / `--agent` CLI flags and per-workspace metadata overrides. Agents and operators need the CLI/UI contract updated alongside code, but `skills/c11/SKILL.md` and user-facing docs are not in the file-level change list.
**Recommendation:** Add `skills/c11/SKILL.md` (and any other affected skill files) to the change list with examples for `new-surface`, `new-split`, `--bash`, `--agent`, and the workspace metadata override. Include verification steps for UI menu behavior and CLI behavior.

**[MINOR] Menu wording "a second menu item" undercounts existing items** *(claude)*
The "New Surface" block at `c11App.swift:968` is already a `Menu` with three items (New Terminal, New Browser, New Markdown). The plan says "add a second menu item" for "New Bash Terminal," which would be a fourth. Also: keyboard-shortcut decision is unaddressed.
**Recommendation:** Reword to "add a fourth item alongside New Terminal / New Browser / New Markdown" and decide whether "New Bash Terminal" gets a shortcut (e.g., `Shift+Cmd+T`) or stays menu-only.

**[MINOR] AgentDetector / AgentChip / AgentRestartRegistry overlap is unmentioned** *(claude)*
`Sources/AgentDetector.swift`, `Sources/AgentChip.swift`, and `Sources/AgentRestartRegistry.swift` already exist for runtime detection, sidebar chips, and restart behavior. The plan doesn't say whether the new launched-agent path interacts correctly with them.
**Recommendation:** Add a sentence stating that AgentDetector picks up the launched process via its normal path (the `Resources/bin/claude` wrapper already calls `c11 set-agent`). Manual-verify chip + restart in a tagged build during implementation. If the chip/restart path doesn't fire, that's design work, not implementation.

**[MINOR] `.cmux/agents.json` legacy fallback decision is implicit** *(claude)*
`WorkspaceBlueprintStore` walks both `.c11/blueprints/` and legacy `.cmux/blueprints/`. The plan only mentions `.c11/agents.json`. Probably correct (this is new), but per the "Keep upstream cmux features" memory it deserves an explicit line.
**Recommendation:** Add a one-liner under per-project discovery stating `.cmux/agents.json` is intentionally NOT checked because this feature is c11-only.

**[MINOR] `CwdMode` two-field shape leaks into the resolver boundary** *(claude)*
`DefaultAgentConfig.cwdMode` (`.inherit` / `.fixed`) plus `fixedCwd: String` overlaps with the existing `workingDirectory: String?` parameter (nil = inherit). The two-field shape is only useful at the Settings-UI form layer.
**Recommendation:** Keep `cwdMode` + `fixedCwd` in the persisted struct if it makes the Settings UI cleaner, but state that `DefaultAgentResolver.resolve(...)` collapses them to a single `workingDirectory: String?` for downstream code.

## 4. Positive Observations

Both reviewers praised:

- **Clean in-scope / deferred split with an operator-confirmed boundary.** Named presets, lineage composition, and per-workspace UI are explicitly deferred. This prevents scope creep and gives reviewers a yardstick.
- **Sound implementation order.** Data model + resolver + tests first (cheapest to iterate via `c11-logic`), CLI flags next, UI and translator last. Matches the codebase's actual iteration economics.
- **Logic-only test emphasis.** Correctly leans on the `c11-logic` scheme rather than host-app tests, given the PR #164 history.
- **File-level change list with new/modify column** makes PR-time review tractable.

Claude additionally noted:

- **Honors the "c11 is unopinionated about TUI config" principle.** Explicit rejection of `c11 install <tui>` and confirmation that `Resources/bin/` wrappers are untouched.
- **Typing-latency hot paths explicitly cleared.** Risk register names `WindowTerminalHostView.hitTest`, `TabItemView`, `TerminalSurface.forceRefresh` and confirms no work touches them.
- **Localization workflow follows the translator-sub-agent pattern** and correctly sequences it after English strings stabilize.
- **Acknowledges abandoned C11-14 branches.** Prevents accidental resurrection of orphaned CMUX-37 work.
- **All three `TerminalController` line references verified accurate.** Plan was written against current code, not from memory.

## 5. Reviewer Agreement

**Strong agreement (both flagged):**

- Initial-prompt delivery via `<<<` / stdin is wrong for interactive TUIs (claude: CRITICAL; codex: MAJOR).
- Shell-quoting of `extraArgs` / `customCommand` is undefined (claude: CRITICAL; codex: MINOR — different severity, same defect).
- `remoteTerminalStartupCommand` interaction is unresolved (both: MAJOR).
- `--agent=default` semantics conflict with the bash-fallback story (both: MAJOR / MINOR).
- The in-scope / deferred split, implementation order, and file-level change list are well-shaped.

**Codex-only:**

- The plan does not reconcile with the existing `AgentLauncherSettings` / `launchAgentSurface` system (MAJOR). This is the most consequential codex-unique finding — claude missed this entirely, and it would leave two competing UIs in the product.
- Skill / operator-docs missing from the change list (MINOR).

**Claude-only:**

- Test-target placement risk via pbxproj membership (CRITICAL) — codebase-specific concern that codex did not surface.
- Missing `newTerminalSurfaceInFocusedPane` plumbing (MAJOR).
- cwd disambiguation across call paths (MAJOR).
- JSON-in-metadata-string awkwardness (MINOR).
- AgentDetector / AgentChip / AgentRestartRegistry overlap (MINOR).
- Menu wording undercount + keyboard shortcut decision (MINOR).
- `.cmux/agents.json` legacy explicit-rejection note (MINOR).
- `CwdMode` two-field shape at resolver boundary (MINOR).

**Severity disagreement:** Codex rated the shell-quoting issue as MINOR while claude rated it CRITICAL. The merged review elevates it to CRITICAL because the plan ships free-text fields into auto-executed commands and the execution model is genuinely undefined — minor only if the answer turns out to be trivial, which it doesn't.

**Not represented:** gemini's review failed or timed out and contributed no findings.
