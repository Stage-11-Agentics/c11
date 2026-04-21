# c11 Orchestration

Patterns for running multiple agents in parallel panes: layout, tab naming, launching sub-agents, agent-to-agent communication, sidebar reporting. The binary is `c11` (a `cmux` compat alias dispatches to the same binary).

## Contents

- [Layout philosophy](#layout-philosophy)
- [Tab naming (mandatory)](#tab-naming-mandatory)
- [Launching sub-agents in panes](#launching-sub-agents-in-panes)
- [Ready-state polling](#ready-state-polling)
- [Agent-to-agent communication](#agent-to-agent-communication)
- [Sub-agent self-reporting](#sub-agent-self-reporting)
- [Monitoring agents from the orchestrator](#monitoring-agents-from-the-orchestrator)
- [Writing c11-aware agent prompts](#writing-c11-aware-agent-prompts)

## Layout philosophy

**Workspace = project. Panes = concerns. Surfaces = individual agents or views.**

Do **not** create one workspace per agent. A workspace is a project; agents are surfaces (tabs) within panes of that workspace.

Standard orchestration layout for a single project:

```
┌─────────────────────┬──────────────────────┐
│                     │  Dashboard / Board   │
│   Orchestrator      │  (browser pane)      │
│   (Claude Code)     ├──────────────────────┤
│   Full height       │  Sub-agent tabs      │
│                     │  (terminal pane)     │
│                     │  [agent1|agent2|...] │
└─────────────────────┴──────────────────────┘
```

- **Left pane** (full height): orchestrator / delegation agent.
- **Right top pane**: task dashboard (browser surface — GitHub issues, a Kanban board, Lattice).
- **Right bottom pane**: sub-agent tabs (terminal surfaces, one per task).

Read `c11 tree` before reshaping — splits reshape the screen and disorient every agent and operator looking at it. For multiple related outputs, prefer tabs (`c11 new-surface`) over splits. Propose layouts; do not impose them.

## Tab naming (mandatory)

**Name every tab, including your own.** An unnamed "Claude Code" tab is an unidentifiable agent — useless when multiple agents are running. The sidebar truncates from the right; the full title shows in the title bar.

### Lineage is the default

When a pane is downstream of another — a sub-agent an orchestrator spawned, a code review spawned over a feature's work, a fix agent rooted in a review finding — the title must show the chain. Use `::` (double colon) as the separator, **parent first**. Multiple rungs chain in order:

| Pane | Title |
|------|-------|
| Feature agent | `Login Button` |
| Its multi-agent review | `Login Button :: MA Review` |
| One reviewer inside that review | `Login Button :: MA Review :: Claude` |
| A fix agent spawned from a review finding | `Login Button :: Fix Null Check` |

Parent-first groups siblings in the sidebar — they all truncate to the parent's leading word (`Login Bu…`), which is usually what the operator wants at a glance: "these panes are all Login Button family." The full chain survives in the title bar. Keep each segment short so the whole chain stays readable: `Login Button :: MA Review :: Claude` wraps cleanly; `Adding Login Button Feature :: Multi-Agent Code Review :: Claude Reviewer` will overflow.

The user may override any tab name; lineage is the default, not a lock.

### Who writes the lineage

- **Orchestrator spawning a sub-agent.** Name the child's tab immediately after `c11 new-surface` / `c11 new-split`, **before** launching the sub-agent or sending the prompt. The orchestrator knows the full lineage (its own title plus the child's role) so it's the right actor to compose. It also writes the description with a lineage breadcrumb — see below.
- **Sub-agent orienting itself.** Before calling `c11 rename-tab`, read the existing title with `c11 get-titlebar-state`. If a chain is already there (orchestrator pre-named it), **preserve the prefix** and refine only the trailing segment if your role needs sharpening. If no title exists, extract lineage from your initial prompt (orchestrators should pass it explicitly) and compose `<parent> :: <your role>`. Only fall back to a lineage-free name when no parent exists.
- **Solo agent (no parent).** Name with your mission, no `::` prefix.

### Description tells the story up the chain

The **description** on a downstream pane should explain *where the work came from and why* — not just what this pane is doing right now. Lead with a breadcrumb line, then the current context:

```bash
c11 set-description --workspace $WS --surface $SURF "Lineage: Login Button → Multi-Agent Review → Claude reviewer.
Reviewing PR #42 for correctness, style, and edge cases. One of three parallel reviewers; findings merge upstream."
```

The orchestrator writes the first lineage line when it spawns the child so the child inherits a correct chain. Sub-agents updating the description mid-session preserve the lineage line — don't strip it on task change. Without it, the operator has to walk the pane tree to reconstruct why a surface exists.

### Conventions by role (examples)

- **Orchestrators / delegators:** name on startup. Role + project in 2–4 words.
  `c11 rename-tab "SIG Delegator"`, `c11 rename-tab "Review Orchestrator"`
- **Sub-agents:** orchestrator composes lineage right after creating the surface:
  `c11 rename-tab --workspace $WS --surface $SURF "Login Button :: Plan"`
  `c11 rename-tab --workspace $WS --surface $SURF "Login Button :: Lint Fixes"`
- **Solo agents (no parent):** mission only, no lineage prefix.
  `c11 rename-tab "Fix Auth Tests"`, `c11 rename-tab "CSS Cleanup"`

`c11 rename-tab` is an alias for `c11 set-title` — either command writes the canonical `title` metadata key on the target surface. The description (including the lineage breadcrumb) goes via `c11 set-description`.

## Launching sub-agents in panes

Use **`cc`** (the `--dangerously-skip-permissions` alias) — never bare `claude` or `claude -p`:

- **`claude -p` (headless)** breaks the c11 auth chain. The subprocess is reparented to `launchd` and cannot call any `c11` command. Sub-agents lose the ability to self-report.
- **Plain `claude`** stalls on every tool call waiting for permission approvals nobody answers.
- **`cc` in an interactive pane** inherits c11 env vars, preserves the auth chain, and skips approvals. Sub-agents can self-report via `c11 set-status`, `c11 log`, `c11 set-progress`, `c11 set-metadata`.

### Standard launch pattern

```bash
# 1. Create the pane (note the new surface ref from output)
c11 new-split right
# → returns surface:NNN

# 2. Launch cc
c11 send --workspace $WS --surface $SURF "cc"
c11 send-key --workspace $WS --surface $SURF enter

# 3. Wait for cc to be ready (see polling section), then name the tab with lineage
#    (parent first, `::` separator — see Tab naming above)
c11 rename-tab       --workspace $WS --surface $SURF "Login Button :: Lint Fixes"
c11 set-description  --workspace $WS --surface $SURF "Lineage: Login Button → Lint Fixes sub-agent.
Clearing lint errors in src/ before the feature branch merges."

# 4. Declare what this agent is (so the sidebar chip, title bar, and tree all reflect identity)
c11 set-agent --workspace $WS --surface $SURF --type claude-code --model claude-opus-4-7

# 5. Send the prompt — always as two calls (send, then send-key enter).
#    Tell the sub-agent its parent so it can preserve the chain on self-updates.
c11 send --workspace $WS --surface $SURF "Your tab title is already set to 'Login Button :: Lint Fixes' — preserve that prefix. Now: fix all lint errors in src/"
c11 send-key --workspace $WS --surface $SURF enter
```

**Why two-call send:** `\n` in `c11 send` is stripped by Claude Code's Bash tool before reaching c11, so the command sits unsent on the sub-agent's prompt line. Always pair `send` with a separate `send-key enter`.

### For complex prompts: deliver via temp file

Shell escaping of backticks, quotes, and markdown in `c11 send` is brittle. For prompts longer than a sentence or containing special characters:

```bash
# 1. Write the prompt to a file
cat > /tmp/agent-prompt.md <<'EOF'
[complex prompt with backticks, code blocks, etc.]
EOF

# 2. Tell the agent to read it
c11 send --workspace $WS --surface $SURF "Read /tmp/agent-prompt.md and follow the instructions."
c11 send-key --workspace $WS --surface $SURF enter
```

## Ready-state handoff

`cc` takes a few seconds to start. Do not `sleep 5` and do not screen-scrape for the prompt glyph. Two patterns solve this depending on whether you need a post-boot conversation or a single-turn handoff.

### Preferred — one-shot prompt via cc argv

For the common orchestration case ("spawn a fresh-context sub-agent with a complete brief"), pass the initial prompt to `cc` as a positional argument. cc boots and submits the message in one step, so there is no ready-state race to solve:

```bash
# Complex prompt → stage to file (shell escaping in c11 send is brittle)
cat > /tmp/agent-prompt.md <<'EOF'
[full prompt here, with backticks / code blocks / etc.]
EOF

# One-shot launch — cc consumes the short argv instruction, which points it at the file
c11 send --workspace $WS --surface $SURF "cd /path && cc \"Read /tmp/agent-prompt.md and follow the instructions.\""
c11 send-key --workspace $WS --surface $SURF enter
```

This is the default for orchestrated sub-agents. No polling, no sleep, no screen-scraping. Works regardless of how many other cc surfaces are in the workspace.

### Fallback — polling the workspace `claude_code` status

When you need cc interactive first (e.g. to send follow-up messages over the course of the session) and can guarantee no sibling cc is running concurrently in the workspace, you can poll the sidebar status that cc's PATH wrapper populates:

```bash
# Wait for cc to reach Idle before sending the prompt
until c11 list-status --workspace $WS 2>/dev/null | grep -q '^claude_code=Idle '; do sleep 1; done
c11 send --workspace $WS --surface $SURF "Read /tmp/prompt.md and follow the instructions."
c11 send-key --workspace $WS --surface $SURF enter
```

Supported status values: `Idle` (prompt waiting), `Running` (processing a turn), `Needs input` (permission/dialog), plus opt-in verbose tool descriptions. Values are `TitleCase`. The trailing space in the grep anchors the match to just `Idle`.

> **Critical gotcha — workspace aggregation.** `c11 list-status` is workspace-scoped; `--surface` is silently ignored. The `claude_code=...` row reflects activity across **every** cc surface in the workspace, not the one you're targeting. With two or more cc's running (orchestrator + sub-agent, planner + triage + impl, or any parallel review fan-out), the row never decisively reports `Idle` and the `until` loop deadlocks. Prefer the one-shot pattern above whenever any sibling cc is in flight. This gotcha is a known binary limitation (no surface-scoped agent-status query exists); there is no polling recipe that safely substitutes in the multi-cc case.

Additional notes on the polling signal:
- The signal only exists when cc was launched through c11's bundled PATH. A cc / claude invocation that bypasses the PATH wrapper will not emit status. For sub-agents you orchestrate from inside a c11 surface this is almost always fine — the wrapper is the default for `cc` / `claude` in that context.
- Other TUIs (codex, kimi, opencode, etc.) do **not** get an equivalent wrapper, by design. For those, agents self-report by calling `c11 set-metadata --key status --value idle` / `running` themselves, following instructions in the c11 skill file they load at session start. If an agent hasn't been taught to self-report, you won't see status for them — that's expected.

**Do not** regex for `❯`, `> `, or `Welcome to Claude Code`. Those patterns drift across cc releases and produce silent stalls when they miss (v2.1.114 dropped the box prompt and changed the banner, breaking every previous recipe). Use one-shot argv delivery, or poll the status row when it's safe to do so.

### Why this works only for cc, and why that's okay

The cc PATH wrapper at `Resources/bin/claude` is a **grandfathered, cc-specific concession** — c11 does not write to any TUI's persistent config, and will not install analogous wrappers for codex, kimi, or opencode. The host is deliberately unopinionated about the terminal: c11 provides the surface, the socket, and the skill file; what an agent does with them is the agent's business. For every TUI except cc, the skill-driven self-reporting path above is how status gets populated — there is no installer, no config-writing, no hook injection performed by c11.

## Agent-to-agent communication

Sub-agents can `c11 send` directly into each other's terminals — no orchestrator relay required.

```bash
c11 send --workspace workspace:N --surface surface:M "The number is 42"
c11 send-key --workspace workspace:N --surface surface:M enter
```

This is a powerful primitive for handoffs: agent A finishes a step, writes its result to agent B's terminal.

Structured handoffs can also ride on the metadata blob — agent A writes `c11 set-metadata --workspace $WS --surface $B_SURF --json '{"handoff":{"from":"A","result":"..."}}'`, and agent B polls with `c11 get-metadata --key handoff`. Pull-on-demand only; there is no subscribe in v1.

## Sub-agent self-reporting

Because `cc` preserves the auth chain, sub-agents can update the sidebar and the metadata blob directly:

```bash
c11 set-status task "3/5 complete" --icon "play.fill" --color "#00FF00"
c11 set-progress 0.6 --label "3/5 subtasks"
c11 log --source "agent-name" "Finished the data model step"

# Richer — canonical metadata keys light up sidebar chip and title bar.
# When refining title/description, check `c11 get-titlebar-state` first and
# preserve any lineage prefix (`Parent :: …`) and lineage line in the description.
c11 set-metadata --json '{"role":"reviewer","status":"running","progress":0.6}'
c11 set-title "Login Button :: Review"
c11 set-description "Lineage: Login Button → Review sub-agent.
Reviewing PR #42 in 3 stages. Stage 2 running smoke tests."
```

The orchestrator does not need to poll on their behalf. When writing agent prompts, explicitly instruct the sub-agent to call these commands at milestones.

## Monitoring agents from the orchestrator

```bash
# Read what a sub-agent is doing
c11 read-screen --workspace workspace:N --surface surface:M --lines 50

# Pull a sub-agent's structured state
c11 get-metadata --workspace $WS --surface $SURF

# Report aggregate progress from the orchestrator
c11 set-status task "3/5 agents complete" --icon "play.fill" --color "#00FF00"
c11 set-progress 0.6 --label "3/5 subtasks"
c11 log --source "orchestrator" "Agent A finished; Agent B starting"
```

## Writing c11-aware agent prompts

When spawning sub-agents in c11, include these as first-class instructions in the prompt:

1. **Self-identify immediately.** First action: `c11 identify` + `c11 get-titlebar-state` (to read any lineage the orchestrator pre-wrote) + `c11 rename-tab "<descriptive name>"` + `c11 set-agent --type <tui> --model <model-id>`. An unnamed, undeclared tab is an unidentifiable agent. If a lineage prefix (`Parent :: …`) is already present, preserve it and refine only the trailing segment.
2. **Name every tab you create with lineage.** Format: `<parent title> :: <child role>` (e.g., `Login Button :: Plan`). Chain additional rungs as needed. Also write `c11 set-description` with a `Lineage: A → B → C` breadcrumb so the sub-agent inherits the chain and preserves it when self-updating. Pass the parent title in the spawn prompt so the sub-agent can recompose if it ever has to rename from scratch.
3. **Report at milestones** via `c11 set-metadata`, `c11 set-status`, `c11 set-progress`, `c11 log`. Interactive `cc` inherits the auth chain, so sub-agents can self-report. Preserve any lineage prefix/breadcrumb when updating title/description on task change.
4. **Deliver complex prompts via temp files** — write to a file, tell the agent to read it. Avoids shell-escaping issues with `c11 send`.
5. **Do not make silent splits.** For multiple related outputs, prefer tabs over splits. Propose layouts when they would help; do not impose them.
6. **Read the room before reshaping it.** `c11 tree --json` gives pixel and percent coordinates for every pane — check whether a new split will fit before asking for one.
