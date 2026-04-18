# c11mux Orchestration

Patterns for running multiple agents in parallel panes: layout, tab naming, launching sub-agents, agent-to-agent communication, sidebar reporting. The binary is `cmux`.

## Contents

- [Layout philosophy](#layout-philosophy)
- [Tab naming (mandatory)](#tab-naming-mandatory)
- [Launching sub-agents in panes](#launching-sub-agents-in-panes)
- [Ready-state polling](#ready-state-polling)
- [Agent-to-agent communication](#agent-to-agent-communication)
- [Sub-agent self-reporting](#sub-agent-self-reporting)
- [Monitoring agents from the orchestrator](#monitoring-agents-from-the-orchestrator)
- [Writing c11mux-aware agent prompts](#writing-c11mux-aware-agent-prompts)

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

Read `cmux tree` before reshaping — splits reshape the screen and disorient every agent and operator looking at it. For multiple related outputs, prefer tabs (`cmux new-surface`) over splits. Propose layouts; do not impose them.

## Tab naming (mandatory)

**Name every tab, including your own.** An unnamed "Claude Code" tab is an unidentifiable agent — useless when multiple agents are running. The sidebar truncates from the right, so the most distinctive word must appear first.

Conventions:

- **Orchestrators / delegators:** name on startup. Role + project in 2–4 words.
  `cmux rename-tab "SIG Delegator"`, `cmux rename-tab "Review Orchestrator"`
- **Sub-agents:** the orchestrator names the tab **immediately after creating the surface**, before sending the prompt.
  `cmux rename-tab --workspace $WS --surface $SURF "TICKET-ID Plan"`
  `cmux rename-tab --workspace $WS --surface $SURF "Lint Fixes"`
- **Solo agents (not part of orchestration):** still name the tab with your mission.
  `cmux rename-tab "Fix Auth Tests"`, `cmux rename-tab "CSS Cleanup"`

Aim for under 25 characters. "Lint Fixes" survives truncation; "Fixing Lint Errors" becomes "Fixing Lin…". When multiple agents work the same material, use a `Role: Subject` prefix to disambiguate (e.g., `OnePager: Spike`, `PR: Brand`, `Podcast: Interview`).

`cmux rename-tab` is an alias for `cmux set-title` — either command writes the canonical `title` metadata key on the target surface (M7). A full description (e.g., "Running smoke suite across 10 shards; reports to Lattice task lat-412") goes via `cmux set-description`.

## Launching sub-agents in panes

Use **`cc`** (the `--dangerously-skip-permissions` alias) — never bare `claude` or `claude -p`:

- **`claude -p` (headless)** breaks the c11mux auth chain. The subprocess is reparented to `launchd` and cannot call any `cmux` command. Sub-agents lose the ability to self-report.
- **Plain `claude`** stalls on every tool call waiting for permission approvals nobody answers.
- **`cc` in an interactive pane** inherits c11mux env vars, preserves the auth chain, and skips approvals. Sub-agents can self-report via `cmux set-status`, `cmux log`, `cmux set-progress`, `cmux set-metadata`.

### Standard launch pattern

```bash
# 1. Create the pane (note the new surface ref from output)
cmux new-split right
# → returns surface:NNN

# 2. Launch cc
cmux send --workspace $WS --surface $SURF "cc"
cmux send-key --workspace $WS --surface $SURF enter

# 3. Wait for cc to be ready (see polling section), then name the tab
cmux rename-tab --workspace $WS --surface $SURF "TICKET-ID Phase"

# 4. Declare what this agent is (so the sidebar chip, title bar, and tree all reflect identity)
cmux set-agent --workspace $WS --surface $SURF --type claude-code --model claude-opus-4-7

# 5. Send the prompt — always as two calls (send, then send-key enter)
cmux send --workspace $WS --surface $SURF "fix all lint errors in src/"
cmux send-key --workspace $WS --surface $SURF enter
```

**Why two-call send:** `\n` in `cmux send` is stripped by Claude Code's Bash tool before reaching c11mux, so the command sits unsent on the sub-agent's prompt line. Always pair `send` with a separate `send-key enter`.

### For complex prompts: deliver via temp file

Shell escaping of backticks, quotes, and markdown in `cmux send` is brittle. For prompts longer than a sentence or containing special characters:

```bash
# 1. Write the prompt to a file
cat > /tmp/agent-prompt.md <<'EOF'
[complex prompt with backticks, code blocks, etc.]
EOF

# 2. Tell the agent to read it
cmux send --workspace $WS --surface $SURF "Read /tmp/agent-prompt.md and follow the instructions."
cmux send-key --workspace $WS --surface $SURF enter
```

## Ready-state polling

`cc` takes a few seconds to start. Do not `sleep 5` and do not screen-scrape for the prompt glyph — the `Resources/bin/claude` wrapper (which fires when you launch `cc` or `claude` from a c11mux surface) already installs a cc hook set that writes **workspace-level status** to a canonical `claude_code` sidebar entry. Read that entry instead.

Supported values: `Idle` (prompt waiting), `Running` (processing a turn), `Needs input` (permission/dialog), plus opt-in verbose tool descriptions. Values are `TitleCase`.

```bash
# Wait for cc to reach Idle before sending the prompt
until cmux list-status --workspace $WS 2>/dev/null | grep -q '^claude_code=Idle '; do sleep 1; done
cmux send --workspace $WS --surface $SURF "Read /tmp/prompt.md and follow the instructions."
cmux send-key --workspace $WS --surface $SURF enter
```

(The trailing space in the grep anchors the match to just `Idle` and not `Idle something-else` in the unlikely case of value drift.)

- `cmux list-status --workspace $WS` shows every sidebar entry on that workspace; the `claude_code` row is what cc's hooks populate.
- This is a **workspace-level** signal — if you have multiple cc surfaces in the same workspace, it will reflect whichever most recently emitted. For strict per-surface ordering, dispatch one sub-agent per workspace or sequence launches.
- The signal only exists when cc was launched through c11mux's bundled PATH. A cc / claude invocation that bypasses the PATH wrapper will not emit status. For sub-agents you orchestrate from inside a c11mux surface this is almost always fine — the wrapper is the default for `cc` / `claude` in that context.
- Other TUIs (codex, kimi, opencode, etc.) do **not** get an equivalent wrapper, by design. For those, agents self-report by calling `cmux set-metadata --key status --value idle` / `running` themselves, following instructions in the cmux skill file they load at session start. If an agent hasn't been taught to self-report, you won't see status for them — that's expected.

**Do not** regex for `❯`, `> `, or `Welcome to Claude Code`. Those patterns drift across cc releases and produce silent stalls when they miss (v2.1.114 dropped the box prompt and changed the banner, breaking every previous recipe). Read the status instead.

### Why this works only for cc, and why that's okay

The cc PATH wrapper at `Resources/bin/claude` is a **grandfathered, cc-specific concession** — c11mux does not write to any TUI's persistent config, and will not install analogous wrappers for codex, kimi, or opencode. The host is deliberately unopinionated about the terminal: c11mux provides the surface, the socket, and the skill file; what an agent does with them is the agent's business. For every TUI except cc, the skill-driven self-reporting path above is how status gets populated — there is no installer, no config-writing, no hook injection performed by c11mux.

## Agent-to-agent communication

Sub-agents can `cmux send` directly into each other's terminals — no orchestrator relay required.

```bash
cmux send --workspace workspace:N --surface surface:M "The number is 42"
cmux send-key --workspace workspace:N --surface surface:M enter
```

This is a powerful primitive for handoffs: agent A finishes a step, writes its result to agent B's terminal.

Structured handoffs can also ride on the metadata blob — agent A writes `cmux set-metadata --workspace $WS --surface $B_SURF --json '{"handoff":{"from":"A","result":"..."}}'`, and agent B polls with `cmux get-metadata --key handoff`. Pull-on-demand only; there is no subscribe in v1.

## Sub-agent self-reporting

Because `cc` preserves the auth chain, sub-agents can update the sidebar and the metadata blob directly:

```bash
cmux set-status task "3/5 complete" --icon "play.fill" --color "#00FF00"
cmux set-progress 0.6 --label "3/5 subtasks"
cmux log --source "agent-name" "Finished the data model step"

# Richer — canonical metadata keys light up sidebar chip and title bar
cmux set-metadata --json '{"role":"reviewer","status":"running","progress":0.6}'
cmux set-title "TICKET-42 — stage 2/3"
cmux set-description "Reviewing PR #42 in 3 stages. Stage 2 running smoke tests."
```

The orchestrator does not need to poll on their behalf. When writing agent prompts, explicitly instruct the sub-agent to call these commands at milestones.

## Monitoring agents from the orchestrator

```bash
# Read what a sub-agent is doing
cmux read-screen --workspace workspace:N --surface surface:M --lines 50

# Pull a sub-agent's structured state
cmux get-metadata --workspace $WS --surface $SURF

# Report aggregate progress from the orchestrator
cmux set-status task "3/5 agents complete" --icon "play.fill" --color "#00FF00"
cmux set-progress 0.6 --label "3/5 subtasks"
cmux log --source "orchestrator" "Agent A finished; Agent B starting"
```

## Writing c11mux-aware agent prompts

When spawning sub-agents in c11mux, include these as first-class instructions in the prompt:

1. **Self-identify immediately.** First action: `cmux identify` + `cmux rename-tab "<descriptive name>"` + `cmux set-agent --type <tui> --model <model-id>`. An unnamed, undeclared tab is an unidentifiable agent.
2. **Name every tab you create** (e.g., `TICKET-ID brief-description`).
3. **Report at milestones** via `cmux set-metadata`, `cmux set-status`, `cmux set-progress`, `cmux log`. Interactive `cc` inherits the auth chain, so sub-agents can self-report.
4. **Deliver complex prompts via temp files** — write to a file, tell the agent to read it. Avoids shell-escaping issues with `cmux send`.
5. **Do not make silent splits.** For multiple related outputs, prefer tabs over splits. Propose layouts when they would help; do not impose them.
6. **Read the room before reshaping it.** `cmux tree --json` gives pixel and percent coordinates for every pane — check whether a new split will fit before asking for one.
