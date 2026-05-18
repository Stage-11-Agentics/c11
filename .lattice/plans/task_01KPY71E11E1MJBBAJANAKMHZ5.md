# C11-14: Default agent — what the per-pane A button launches

Single canonical setting for the A-button-launched agent, with c11's skill files lifted to a peer section. Terminals remain bash; the A button is the agent path. One way to do a given action.

## Motivation

Surfaced while orchestrating C11-13: the delegator was launched via `claude --dangerously-skip-permissions` and quietly booted on Sonnet 4.6 because no `--model` was passed. More broadly, the operator had no single home for "what every agent I launch in c11 should be." `AgentLauncherSettings` partially served this for the A button, but its UI was thin (a picker only) and it didn't compose with project-level overrides or initial prompts.

## Scope (final shape, ratified by the operator after two rounds of UX iteration)

**In scope (delivered in this PR):**

- New top-level Settings page **Agents** with the `a.circle` sidebar icon — matches the per-pane A button glyph so operators learn the correlation visually.
- **`c11 skills`** section (renamed from the old "Agent Skills") moved above default agent. Helper text clarifies these are c11's skill files installed into each agent's skill folder (Claude Code, Codex, …).
- **`default agent`** section with:
  - Single picker `default agent: [Claude Code ▾]` over the five agent types (claude-code, codex, kimi, opencode, custom). Bash is intentionally not an option — terminals are the bash path.
  - Per-agent subsection labeled `Agent Claude Code` / `Agent Codex` / … with three fields:
    - `command` — editable shell line. Factory defaults: `claude --dangerously-skip-permissions`, `codex --yolo`, `kimi`, `opencode`, empty for custom. Per-agent help text reads `the shell line that runs when we launch the <agent name> agent. you can include any parameters to match your specification.`
    - `initial prompt` — optional. Factory default for every built-in agent: `load the c11 skill`. Help: `optional. given to the agent immediately after it boots.`
    - `▸ environment overrides — advanced users only` — disclosure triangle (custom Button + chevron because SwiftUI's `DisclosureGroup` misbehaved inside the c11 `SettingsCard`). Collapsed by default. Multi-line `KEY=value` editor; parsed at use time.
  - `reset agent to defaults` button per-agent.
- Agent-scoped notes above the card: `the A button on every pane launches this. new terminal still opens bash. drop a .c11/agents.json in any repo to override these settings for terminals opened there.`
- **Per-project override** via `.c11/agents.json` at the repo root (walked upward from cwd, bounded 64 levels). File shape matches the user-level JSON blob.
- **Right-click on the per-pane A button** shows the five agent types; selecting one updates the same `defaultAgent` field the Settings picker writes — operators can switch the default from inside a workspace without opening Settings.
- **`AgentLauncherSettings` enum is gone.** All call sites (Workspace.launchAgentSurface, the tab-bar tooltip, AppDelegate workspace-plan launch path) read from `DefaultAgentConfigStore.shared` instead. One canonical store, no parallel UIs.
- **Socket / CLI**: agents are first-class operators of this surface. New commands:
  - `c11 default_agent get` — print current default agent type.
  - `c11 default_agent set <type>` — change default; validates type.
  - `c11 default_agent launch [--agent <type>] [--pane <id>]` — equivalent to clicking A; explicit agent overrides default for one launch.
  - `c11 agent_config get <type>` — emits JSON `{ command, initial_prompt, env_overrides }`.
  - `c11 agent_config set <type> [--command "…"] [--initial-prompt "…"] [--env-overrides "…"] [--reset]` — per-field updates or factory reset.
- **`Automation` Settings page** (renamed from "Agents & Automation"): holds the leftover Permissions, Socket Access, and Agent Integrations sections.
- 37 logic-only tests via the `c11-logic` scheme. Codec, factory defaults, store mutations, project-config discovery, resolver precedence (explicit agent > project default > user default; project per-agent > user per-agent), command builder (claude-code appends initial prompt as a single-quoted positional argument; other agents preserve the prompt in config but don't auto-append), sh-safe single-quote escape.
- All new user-visible strings localized in brand voice (lowercase-leaning, action-verb-first, no em-dashes) and translated for ja / uk / ko / zh-Hans / zh-Hant / ru via `scripts/c11-14-add-localizations.py` (idempotent).

**Deferred (explicit follow-ups):**

- Multiple named presets (`claude-opus`, `claude-haiku`, `codex-yolo` …).
- Sub-agent lineage composition (does the default apply to sibling surfaces a delegator spawns?).
- Per-agent post-ready prompt delivery for codex / kimi / opencode (claude-code gets it via positional arg; others have varying TUI input contracts and we don't fake it with a herestring).
- Workspace-level UI for forcing bash or a specific agent (the workspace metadata key `default_agent_use_bash` from an earlier iteration was dropped — terminals are bash, agents are the A button, no per-workspace fork needed yet).

## Design

### Data model

`AgentType` enum (top-level, replaces the local `AgentLauncherSettings.Kind`):

```swift
enum AgentType: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "claude-code"
    case codex
    case kimi
    case opencode
    case custom

    var displayName: String { … }   // localized
    var factoryCommand: String { … } // built-in default
    var factoryInitialPrompt: String { … } // "load the c11 skill" for everything except custom
}
```

`AgentConfig` (per-agent slot):

```swift
struct AgentConfig: Codable, Equatable {
    var command: String
    var initialPrompt: String
    var envOverridesText: String   // multi-line KEY=value
    var envMap: [String: String] { … } // parsed at use time
}
```

`DefaultAgentConfig` (the whole thing):

```swift
struct DefaultAgentConfig: Codable, Equatable {
    var defaultAgent: AgentType
    var agents: [AgentType: AgentConfig]
}
```

Singleton: `DefaultAgentConfigStore.shared`, backed by UserDefaults key `defaultTerminalAgentConfig.v2`. (v1 was the herestring-era shape from an earlier iteration — the feature has never been released so there is no migration.) The store auto-fills missing per-agent entries from factory at read time, so older / partial blobs don't break.

### Resolver

`DefaultAgentResolver.resolve(explicitAgent:, userDefault:, projectConfig:) -> (AgentType, ResolvedAgentLaunch)`:

1. Pick the agent: `explicitAgent` > `projectConfig?.defaultAgent` > `userDefault.defaultAgent`.
2. Pick the per-agent config: `projectConfig?.agents[agent]` > `userDefault.config(for: agent)`.
3. Build the launch command. For `claude-code` with a non-empty initial prompt, the prompt is appended as a single-quoted positional argument (`claude --dangerously-skip-permissions 'load the c11 skill'` — claude accepts that shape). For other agents the prompt is preserved in config but not auto-appended; operators who want it can include it inline via `command`.
4. Return env overrides parsed from the `KEY=value` lines.

### Launch path

`Workspace.launchAgentSurface(inPane:explicitAgent:)`:

1. Resolve via the function above. `projectConfig` is found by walking up from the focused panel's cwd (`Workspace.resolverCwdForAgentLaunch()`).
2. Create a new terminal panel via `newTerminalSurface(inPane:startupEnvironment:)`. Env from the resolver flows into Ghostty as additional environment at process spawn.
3. After the panel exists, `panel.sendText(command + "\n")` — same queue-until-ready pattern as the welcome workspace. Bash receives the launch command and execs the agent.

The bash / Ghostty startup-command path is preserved for remote-relay startup commands (`remoteTerminalStartupCommand()`); agent launches sit on top of that, not in place of it.

### Settings UI

`Sources/DefaultAgentSettingsView.swift` — self-contained `DefaultAgentSettingsSection` view with a `DefaultAgentSettingsViewModel` that:

- Binds the picker to the store's `defaultAgent` field. Switching the picker writes through immediately and also flips the visible per-agent fields to that agent.
- Loads per-agent fields from the store on `editingAgent` changes. Persists field edits back via `store.update(_:_:)`.
- The env disclosure uses a plain `Button` with chevron + `if showEnvOverrides { … }` because `DisclosureGroup` was misbehaving inside the c11 `SettingsCard` wrapper (the screenshot showed the editor rendered while the chevron read collapsed).

### Sidebar split

`SettingsPage` gets a new `case agents` (icon `a.circle`, second in the order after `general`) and renames `agentsAutomation → automation`. The page builder splits into two:

- `agentsSettingsPage`: c11 skills, then default agent.
- `automationSettingsPage`: permissions, socket access, agent integrations (unchanged content, separate home).

### Tests

`c11Tests/DefaultAgentConfigTests.swift` + `c11Tests/DefaultAgentResolverTests.swift` — 37 logic-only tests on the `c11-logic` scheme. Cover factory defaults, lenient decode, env parsing (blank lines, comments, whitespace), store mutations including the "fills missing agents with factory" path, project-config discovery (present, missing, malformed, deep walk), resolver precedence, command-builder per agent type, sh-safe single-quote escaping. Registered in both `c11Tests` and `c11LogicTests` source build phases via `scripts/c11-14-register-files.rb` (idempotent).

## Plan-review history

The original plan (UserDefaults JSON blob + bash-default-on-T-button + `--bash` flag + herestring stdin for the prompt) was reshaped twice based on plan-review feedback and operator UX redlines:

- **v1 plan-review (triple, claude + codex) returned FAIL** on launch semantics. Fix: switched from Ghostty `initialCommand` startup hook to post-ready `sendText`. Dropped the `<<<` herestring (closed-stdin footgun for interactive TUIs). Pinned shell-quoting model. Reconciled with `AgentLauncherSettings` (initially kept side-by-side; ultimately replaced entirely). Dropped `--agent` CLI flag (named presets deferred).
- **Operator UX iteration** (2026-05-17→18): drop bash from the default-agent picker (T is for terminals, A is for agents — one way to do a given action). Drop the working-directory + model + extra-args fields; the launch command is the whole shell line and the operator authors it. Make per-agent heading `Agent <name>`. Make env overrides advanced-users-only and properly clickable. Move c11 skills above default agent. Promote Agents to its own Settings page with the `a.circle` icon. Default the initial-prompt field to `load the c11 skill` so first-launch agents already know about c11.

The shape that landed is materially different from the original plan — and materially better. Plan-review caught the launch-semantics issues that would have shipped subtly broken behavior; the operator UX rounds collapsed five fields into two and gave the feature a proper sidebar home.

## Files

| File | Change |
|------|--------|
| `Sources/DefaultAgentConfig.swift` | model + store (new shape: `AgentType` + `AgentConfig` + `DefaultAgentConfig`) |
| `Sources/DefaultAgentResolver.swift` | resolver + command builder |
| `Sources/DefaultAgentProjectConfig.swift` | `.c11/agents.json` upward walk |
| `Sources/DefaultAgentSettingsView.swift` | Settings section view + view-model |
| `Sources/c11App.swift` | new `agents` Settings page + sidebar entry + page builder split; old `AgentLauncherSettings` enum + section deleted |
| `Sources/Workspace.swift` | `launchAgentSurface` reads from new store; right-click menu reads/writes new store; tooltip updated |
| `Sources/AppDelegate.swift` | workspace-plan launch path reads from new resolver |
| `Sources/TerminalController.swift` | new socket commands `default_agent` + `agent_config` |
| `Resources/Localizable.xcstrings` | new strings (en + ja/uk/ko/zh-Hans/zh-Hant/ru) |
| `c11Tests/DefaultAgentConfigTests.swift` | 23 tests (factory, codec, env, store, project discovery) |
| `c11Tests/DefaultAgentResolverTests.swift` | 14 tests (precedence, command builder, escaping, env passthrough) |
| `scripts/c11-14-register-files.rb` | idempotent xcodeproj membership for new sources + tests |
| `scripts/c11-14-add-localizations.py` | idempotent string-catalog authoring |

## Out of scope

- `c11 install <tui>` — rejected by design (c11 stays unopinionated about TUI config; we don't write into `~/.claude/`, `~/.codex/`, …).
- A workspace-level "force bash" or "force claude" override — fell out of scope when T was confirmed as always-bash. Per-project `.c11/agents.json` already covers the repo-tagged use case.
