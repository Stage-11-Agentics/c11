# C11-14 in-session code review (fast-track inline review)

Reviewed the diff before opening PR #168. Single-chat mode, so this is the same agent that wrote the implementation — review captures my best read of the diff against the SPEC + plan.

## What passes

- **Data model + resolver are pure and well-tested** (33 logic-only tests; codec, lenient decode, store, project-config discovery, precedence chain, command builder per agent type, sh-safe quote escaping, cwd resolution). Run via `xcodebuild -scheme c11-logic test`.
- **Launch mechanism matches existing patterns.** `Workspace.newTerminalSurface` / `newTerminalSplit` create the panel with `initialCommand = remoteTerminalStartupCommand()` (unchanged for non-agent terminals) and then call `panel.sendText(command + "\n")` for the agent command. Same shape as `AgentLauncherSettings.launchAgentSurface` and the welcome workspace. Interactive TUIs keep stdin; quit-agent-leaves-shell semantics preserved.
- **Precedence chain is single-direction & well-typed.** `Workspace.resolveAgentForNewSurface` → `DefaultAgentResolver.resolve`. Every call site (menu, splits, socket) flows through the same path. cwd source is `Workspace.resolverCwdForNewSurface()` (focused-panel directory → workspace.currentDirectory → process cwd) — disambiguation pinned.
- **Remote-workspace composition is right.** Relay startup command goes via Ghostty's startup hook; agent typed-line follows after shell is ready. `trackRemoteTerminalSurface` continues to fire only for the relay path.
- **Per-workspace override is minimal & flat.** Single boolean `default_agent_use_bash` metadata key. Inline JSON blob dropped per plan-review feedback. Reads cleanly in `c11 list-metadata`.
- **Plan-review v1 verdict is fully addressed.** Every CRITICAL/MAJOR item from the merged review has a corresponding code change. See `.lattice/plans/task_01KPY71E11E1MJBBAJANAKMHZ5.md` § "Plan-review v1 response".
- **Localization done.** 24 strings landed in `Resources/Localizable.xcstrings` for en/ja/uk/ko/zh-Hans/zh-Hant/ru via `scripts/c11-14-add-localizations.py` (idempotent).
- **xcodeproj registration is idempotent and explicit** via `scripts/c11-14-register-files.rb` (adds the new tests to both `c11Tests` and `c11LogicTests` source phases). Resolves the plan-review CRITICAL about test-target placement risk.

## Things to validate manually before merge (test-plan items)

1. **Tagged build manual smoke** — Settings panel: section appears at top of Agents & Automation, picker switches dependent fields, command preview live-updates. The Settings UI is a SwiftUI section so unit tests don't cover it; the validation is visual.
2. **Cmd+T launches the default** with the operator's configured claude config. The `sendText` queue-until-ready path is the existing well-tested code path but should be eyeballed for this new caller.
3. **"New Bash Terminal" menu item bypasses default** even when user default is claude.
4. **Per-workspace `default_agent_use_bash=true` works** via `c11 set-metadata --workspace <id> --key default_agent_use_bash --value true`.
5. **`.c11/agents.json` works** with a hand-authored JSON blob; check the upward walk and malformed-JSON fallback.
6. **AgentChip + AgentRestartRegistry** still fire correctly for the launched-agent process. The `Resources/bin/claude` wrapper does the `c11 set-agent` call; should be unchanged. Restart-after-app-restart should resume the agent.

## What's intentionally NOT covered

- **Multiple named presets** — deferred. `--agent <name>` removed from CLI in this PR; resolver still accepts the param to make follow-up landing easy.
- **Sub-agent lineage composition** — deferred.
- **Per-workspace Settings UI** — deferred (override is exposed via workspace metadata + CLI only).
- **Per-agent prompt delivery for codex/kimi/opencode** — deferred. Initial prompt auto-appends only for claude-code; other agents preserve the field but don't auto-append (different post-ready contracts).
- **Unification with `AgentLauncherSettings`** — deferred. Documented in the Settings card note as intentionally separate.

## Risk

Low. The diff is additive: new files + opt-in parameter on existing Workspace methods (`agentOverride: ResolvedAgent? = nil` defaults to nil → historical behavior). No typing-latency hot path is touched. No socket protocol break (existing callers without `--bash` see the resolver's default chain, which gracefully falls back to bash when no agent is configured).

Verdict: **ready for merge after manual smoke validation.**