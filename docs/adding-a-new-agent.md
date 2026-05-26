# Adding a new coding agent to c11

c11 treats coding agents (Claude Code, Codex, Grok Build, Kimi, OpenCode) as first-class peers: each one is in the A-button picker, gets an icon in the sidebar chip, auto-detects from process listings, can install c11 skills into its config dir, and resumes across snapshots. Adding a new one is mechanical — there's a fixed set of surfaces to extend.

This doc is the checklist. Grok Build is the worked example; replace `grok` / `Grok Build` / `--always-approve` with the new agent's name/flag wherever they appear.

## Pre-flight

Before editing code, capture three facts about the new agent:

1. **Binary name.** What runs on PATH (`grok`, `aider`, `cursor-cli`, …).
2. **Auto-approve flag.** The CLI flag that bypasses per-tool confirmation prompts — c11 launches agents in that mode by default (parallel to `claude --dangerously-skip-permissions`, `codex --yolo`, `grok --always-approve`, `opencode run --dangerously-skip-permissions`). If the agent has no such mode, leave it bare; flag it in the contributor commit so reviewers know.
3. **Resume command.** How the agent picks up its most recent session. `grok --resume`, `codex resume --last`, etc. If there's no stable resume flag, the restart registry launches fresh — best-effort, same as Kimi/OpenCode today.

If the agent's config root convention is `~/.<name>/` (Claude → `~/.claude/`, Grok → `~/.grok/`), the `SkillInstaller` will wire up automatically once you add the enum case. If it isn't, you'll need a small override there too — flag it.

## The surfaces to update

All paths are relative to `code/c11/`. Order doesn't matter — the changes are independent.

### Required (without these the agent does not work as a c11 agent)

1. **`Sources/DefaultAgentConfig.swift` — `AgentType` enum.** Add a new `case` with kebab-case raw value. Extend the three switch statements (`displayName`, `factoryCommand`, `factoryInitialPrompt`). `displayName` uses `String(localized:)` — write English only; spawn a localization sub-agent after (see `CLAUDE.md` → Localization).

2. **`Sources/SurfaceMetadataStore.swift` — `canonicalTerminalTypes`.** Add the kebab-case string. Without this, the sidebar treats the new agent as `unknown` even when explicitly declared.

3. **`CLI/c11.swift` — `default-agent set` valid-types message.** Search for the hard-coded `["claude-code", "codex", ...]` list and add the new value. CLI ergonomics only — the resolver is enum-driven and accepts the new case automatically.

4. **`Sources/AgentChip.swift` — icon mapping.**
   - `iconAssetName(forTerminalType:)`: add a case returning `"AgentIcons/<type>"`.
   - `sfSymbolFallback(forTerminalType:)`: pick an SF Symbol that visually distinguishes the agent. Used until a real asset ships in `Assets.xcassets/AgentIcons/`. Existing fallbacks: `sparkles`, `chevron.left.forwardslash.chevron.right`, `bolt.fill`, `moon.stars`, `curlybraces`. Avoid collisions; the chip is the operator's at-a-glance identifier.

5. **`Sources/AgentDetector.swift` — heuristic `classify`.** Add the binary name(s) to the exact `comm` match. If the binary is wrapped by `node`, add an `args` substring match in the node branch. The detector reads process listings — it does not screen-scrape banners (don't add banner matching; it drifts across releases).

### Strongly recommended (parity with existing agents)

6. **`Sources/AgentRestartRegistry.swift` — `phase1` rows.** Add a `Row(terminalType: "<type>")` with a resolver closure that returns the resume command string (trailing `\n` preserved). If the agent has no resume flag, return a fresh launch command — best-effort matches Kimi/OpenCode.

7. **`Sources/SkillInstaller.swift` — `SkillInstallerTarget`.** Add the enum case (raw value lower-case, matches the `~/.<name>/` config root convention). `displayName` is the user-facing label. Skill files install into `~/.<name>/skills/` automatically.

8. **`Sources/AgentSkillsView.swift` — onboarding sheet opt-ins.** Add `@State private var <name>OptIn: Bool = false`, then thread it through `anySelected`, `optInBinding(for:)`, `applySelection()`, and `applyDefaultOptIns(rows:)`. The Settings view inherits from `AgentType.allCases`, so no extra work there.

### Documentation

9. **`skills/c11/SKILL.md`** — extend the "Common types" list and the per-TUI prompt-delivery one-liner under "Launching sub-agents."

10. **`skills/c11/references/api.md`** — extend the `CMUX_AGENT_TYPE` env-var description and the `--type` accepted-values bullet.

11. **`skills/c11/references/metadata.md`** — extend the `terminal_type` canonical values list.

12. **`skills/c11/references/orchestration.md`** — add a `### <agent>` subsection under "Per-agent launch quirks." Document the auto-approve flag, any auth gotchas, and whether the agent self-reports via the skill or needs special handling.

### Tests

13. **`c11Tests/DefaultAgentConfigTests.swift`** — add a `testFactory<Name>CommandIncludes<Flag>` mirroring the existing claude/codex/grok tests. `testFactoryDefaultsHaveAllAgents` and the codable round-trip tests cover the new case automatically via `AgentType.allCases`.

## Run the tests

```bash
cd code/c11
xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-logic -configuration Debug \
  -destination "platform=macOS" test
```

`c11-logic` is host-free and safe to run locally even when prod c11 is running (see `CLAUDE.md` → "Testing policy"). Wall time ~30s warm.

If you also touched `AgentRestartRegistry.swift`, run `c11-unit` via `scripts/test-unit-local.sh` — `AgentRestartRegistryTests` lives there.

## Validate end-to-end

The clean local path is to build, launch a *tagged* DEV build, and exercise the agent:

```bash
./scripts/reload.sh --tag <slug>
./scripts/launch-tagged-automation.sh <slug>
```

In the tagged build: Settings → Agents & Automation → Agent Launcher Button → pick the new agent, then click the A button on a fresh pane. The agent should launch with its auto-approve flag baked in. Sidebar chip should show the new icon (SF Symbol fallback if no asset shipped).

Do not `open` an untagged `c11 DEV.app` from DerivedData while prod c11 is running — they fight for sockets. See `CLAUDE.md` → "Testing policy" for the why.

## A note on runtime extensibility

Today, agent registration is **compile-time**. Adding a new first-class agent means editing Swift, building c11, and shipping a new build. The `.custom` agent type exists as a partial runtime escape hatch — operators can set Settings → Default Agent → Custom to any launch command without rebuilding — but `.custom` has one slot, no sidebar branding, no auto-detection, and no snapshot resume.

A data-driven agent registry (loading agent definitions from `~/.config/c11/agents/<name>.toml` and contributing rows to the same surfaces above) is feasible and would let operators add fully-branded agents at runtime. It is not built yet. If you find yourself adding a fifth or sixth coding agent and the friction is starting to bite, that's the moment to design it — not before.

## Sequencing for the PR

Land the surfaces (1–8) and tests (13) in one commit. Land the docs (9–12) and the contributor-doc updates (this file) in a second. The reviewer's eye doesn't want to traverse twelve files of Swift *plus* prose at once — and the docs land cleanly even if Swift review takes a round-trip.
