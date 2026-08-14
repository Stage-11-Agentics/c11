# c11 Orchestration

Patterns for running multiple agents in parallel panes: layout, tab naming, launching sub-agents, agent-to-agent communication, sidebar reporting. The binary is `c11`.

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

**By default: workspace ≈ project, panes ≈ concerns, surfaces ≈ individual agents or views.** This is a sensible starting layout, not a law; how the operator maps workspaces to projects overall is their call (see the c11 skill).

Within a single orchestration run, keep the agents as surfaces (tabs) within panes of the run's workspace rather than spawning a fresh workspace per agent. One workspace per agent fragments the run across the sidebar and makes it hard to read; grouping them keeps the whole run legible in one place.

### Isolation is a prompt rule, not a topology rule

**Do not reach for `--new-workspace` to keep agents from influencing each other.** Agents in the same workspace are *already* isolated: separate processes, separate context, no shared state. Nothing about sharing a workspace lets one agent see another's work. If you need agents not to consult each other — independent audits, blind reviews, a bake-off — say so **in the prompt** ("work alone; do not read, message, or coordinate with any other agent, surface, or pane; do not read other agents' transcripts"). That is the only mechanism that actually binds. A separate workspace adds zero isolation and costs real legibility.

Observed failure (2026-07-25): an orchestrator asked to open two blind auditors "as surfaces" spawned each with `--new-workspace`, reasoning that the operator's "don't let them look at each other" called for a hard barrier. The barrier was imaginary — the prompt was already doing the work — and the run ended up scattered across three workspaces the operator then had to hunt through. Note that `launch-agent` defaults to `$C11_WORKSPACE_ID` and the focused pane, so **the correct call was the one with fewer flags**.

Before adding any separation flag, ask what it actually isolates. If the answer is "nothing the prompt doesn't already handle," drop it.

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

### Titles are short and DISTINCT; the description is the live subtitle

- **Title = 2–3 words, role-first, distinct.** Make the FIRST word differ between sibling tabs
  wherever possible — the leading characters are all that survives sidebar truncation.
  `F2 Routes`, `P2 SPA Plan`, `P4 ImportSync Plan`. Never chain the parent's name into a child
  title (no `Parent :: Child`, no shared prefixes): with six siblings the sidebar becomes a
  wall of identical truncated strings, destroying exactly the information the title exists to
  carry. A run's family identity comes from the workspace and from descriptions.
- **Description = current work first, lineage LAST.** The sidebar flattens the description to
  one truncated line after the title, so the opening words must carry the live state — what
  the agent is doing now and the next meaningful gate. Close with a
  `Lineage: <parent> → <role>` breadcrumb as the final line (arrow, never `::`).
- **Ticket IDs need plain English.** `C11-184` may lead a title or appear in a description,
  but the description must still say what the work *is* — the operator should not need a
  tracker lookup to parse the sidebar.

| Pane | Title | Description |
|------|-------|-------------|
| Epic orchestrator | `PostHog Orch` | `Dispatching lanes; F2 and P4 in flight.` |
| A lane's planner | `P2 SPA Plan` | `Drafting SPA routing plan; next, review gate. Lineage: PostHog Orch → P2 planner` |
| A lane's implementer | `F2 Routes` | `Implementing route table; next, smoke tests. Lineage: PostHog Orch → F2 implementer` |
| A review spawned over it | `F2 Review` | `Auditing route diff against spec. Lineage: PostHog Orch → F2 → reviewer` |

The user may override any tab name; these are defaults, not locks.

### Who writes the lineage

- **Orchestrator spawning a sub-agent.** Name the child's tab immediately after `c11 new-surface` / `c11 new-split`, **before** launching the sub-agent or sending the prompt — a short distinct role title, plus a description ending with the lineage breadcrumb. The orchestrator knows the lineage, so it writes it — into the description's last line.
- **Sub-agent orienting itself.** Before calling `c11 rename-tab`, read the existing title with `c11 get-titlebar-state`. If the orchestrator pre-named it, keep that name unless your role sharpened — and keep it SHORT and distinct, never re-expanding it into a `Parent :: Child` chain. Preserve the description's `Lineage:` line on every update.
- **Solo agent (no parent).** Name with your mission.

### Description tells the story up the chain

The **description** on a downstream pane carries both the live state and *where the work came from* — current context first, breadcrumb last:

```bash
c11 set-description --workspace $WS --surface $SURF "Reviewing PR #42 for correctness, style, and edge cases; one of three parallel reviewers, findings merge upstream.
Lineage: Login Button → Multi-Agent Review → Claude reviewer"
```

The orchestrator writes the lineage line when it spawns the child so the child inherits a correct chain. Sub-agents updating the description mid-session preserve it — don't strip it on task change. Without it, the operator has to walk the pane tree to reconstruct why a surface exists.

### Conventions by role (examples)

- **Orchestrators / delegators:** name on startup. Role + project in 2–4 words.
  `c11 rename-tab "SIG Delegator"`, `c11 rename-tab "Review Orchestrator"`
- **Sub-agents:** orchestrator names them right after creating the surface — short, distinct, role-first; lineage goes in the description:
  `c11 rename-tab --workspace $WS --surface $SURF "Login Plan"`
  `c11 rename-tab --workspace $WS --surface $SURF "Lint Fixes"`
- **Solo agents (no parent):** mission only.
  `c11 rename-tab "Fix Auth Tests"`, `c11 rename-tab "CSS Cleanup"`

`c11 rename-tab` is an alias for `c11 set-title` — either command writes the canonical `title` metadata key on the target surface. The description (including the lineage breadcrumb) goes via `c11 set-description`.

## Launching sub-agents in panes

**The one-command path: `c11 launch-agent`.** For launching a *typed* agent —
a specific kind, optionally with a pinned model/effort and an initial prompt —
prefer the dedicated command over hand-composing the steps below:

```bash
c11 launch-agent --type codex --model gpt-5.2 --effort high \
    --prompt-file /tmp/brief.md --title "Login Impl" --json
```

It creates the surface (in a pane, a workspace, or `--new-workspace`), renders
the right per-agent invocation (claude wrapper + skip-permissions, codex
`--yolo` + `-c model_reasoning_effort=`, pi/omp `--thinking`, …), injects
`C11_AGENT_TYPE/MODEL/TASK` into the spawn env, stamps sidebar identity at
birth, and delivers the prompt one-shot via argv where the agent supports it —
no ready-state race. `--json` returns the new surface/pane/workspace refs for
follow-up `send`/`read-screen`. Full reference: `docs/launch-agent-reference.md`.

### Positive launch receipt

`launch-agent` returning a surface ref proves that c11 created a surface and
delivered a prompt. It does **not** prove that the child read the brief, landed in
the intended cwd, resolved the intended work item, or is looking at the expected
git head. For consequential work, the launch prompt requires one positive receipt
back to the parent before the child proceeds:

```text
READY <work-item> CWD <absolute-path> HEAD <sha-or-na> BASE <sha-or-na> MODE <active|standby>
```

For a reviewer, use the sharper verb `REVIEWING` and include the exact head and
base being reviewed. Long-lived prepared seats report `MODE standby` and name the
mutation they have **not** started. The parent verifies the receipt against its own
expected values; a visible TUI, an idle status chip, or a successful launch response
is not a substitute.

c11 owns the surface/liveness fact. The workflow that launched the child owns the
work-specific fields and decides what must match before work can continue. Put the
receipt channel in the prompt: direct `c11 send` to the parent, a metadata handoff,
or a workflow artifact. Do not make the child guess where acknowledgement belongs.

The manual pattern below remains for launches into an *existing* surface, or
when you need custom composition.

Use **`claude --dangerously-skip-permissions`** — never bare `claude` (stalls on approvals) or `claude -p` (headless, breaks the auth chain):

- **`claude -p` (headless)** breaks the c11 auth chain. The subprocess is reparented to `launchd` and cannot call any `c11` command. Sub-agents lose the ability to self-report.
- **Plain `claude`** stalls on every tool call waiting for permission approvals nobody answers.
- **`claude --dangerously-skip-permissions` in an interactive pane** inherits c11 env vars, preserves the auth chain, and skips approvals. Sub-agents can self-report via `c11 set-status`, `c11 log`, `c11 set-progress`, `c11 set-metadata`.

> **`claude` on PATH is the c11 wrapper.** Inside a c11 surface, `claude` resolves to `Resources/bin/claude` — a PATH-scoped wrapper that injects session-id and hook settings so the sidebar gets `claude_code` status. Always invoke `claude --dangerously-skip-permissions` explicitly in anything you send to a pane.

### Standard launch pattern

```bash
# 1. Create the pane (note the new surface ref from output)
c11 new-split right
# → returns surface:NNN

# 2. Launch claude
c11 send --workspace $WS --surface $SURF "claude --dangerously-skip-permissions"

# 3. Wait for claude to be ready (see polling section), then name the tab: short,
#    role-first, DISTINCT first word. Lineage goes in the description's LAST line, never the title.
c11 rename-tab       --workspace $WS --surface $SURF "Lint Fixes"
c11 set-description  --workspace $WS --surface $SURF "Clearing lint errors in src/ before the feature branch merges.
Lineage: Login Button → Lint Fixes sub-agent"

# 3b. Only if you own this worker's completion and blockers (see the attention model
#     in the skill card): suppress it before the agent boots. When in doubt, skip this.
# c11 suppress --surface $SURF

# 4. Declare what this agent is (so the sidebar chip, title bar, and tree all reflect identity)
c11 set-agent --workspace $WS --surface $SURF --type claude-code --model claude-opus-4-7

# 5. Send the prompt. Name the parent so the sub-agent can keep its own lineage line accurate.
c11 send --workspace $WS --surface $SURF "Your tab is named 'Lint Fixes'; your parent is 'Login Button'. Keep the title short and distinct, keep your description current (it is your live subtitle), and keep its last-line 'Lineage:' breadcrumb accurate. Now: fix all lint errors in src/"
```

**One-call send.** `c11 send` types the text and dispatches a synthetic Return on the same turn, so the receiving TUI sees one user turn. Pass `--no-submit` to type without executing (e.g., staging a partial line across multiple calls).

### Spawning multiple panes at once

Loop the spawn pattern. Capture the new surface ref from each `c11 new-split` call so you can target it for the rename and send.

```bash
WS=$(c11 identify | jq -r '.workspace.id')
for ROLE in plan impl review; do
  SURF=$(c11 new-split right | awk '{print $2}')
  c11 rename-tab --workspace $WS --surface $SURF "$ROLE"
  c11 send       --workspace $WS --surface $SURF "claude --dangerously-skip-permissions \"<prompt>\""
done
```

For 5+ agents, swap `c11 new-split right` for `c11 new-surface --pane <pane>` so they land as tabs of one pane instead of unreadably narrow splits.

### For complex prompts: deliver via temp file

Shell escaping of backticks, quotes, and markdown in `c11 send` is brittle. For prompts longer than a sentence or containing special characters:

```bash
# 1. Write the prompt to a file
cat > /tmp/agent-prompt.md <<'EOF'
[complex prompt with backticks, code blocks, etc.]
EOF

# 2. Tell the agent to read it
c11 send --workspace $WS --surface $SURF "Read /tmp/agent-prompt.md and follow the instructions."
```

## Ready-state handoff

`claude` takes a few seconds to start. Do not `sleep 5` and do not screen-scrape for the prompt glyph. Two patterns solve this depending on whether you need a post-boot conversation or a single-turn handoff.

### Preferred — one-shot prompt via claude argv

For the common orchestration case ("spawn a fresh-context sub-agent with a complete brief"), pass the initial prompt to `claude --dangerously-skip-permissions` as a positional argument. It boots and submits the message in one step, so there is no ready-state race to solve:

```bash
# Complex prompt → stage to file (shell escaping in c11 send is brittle)
cat > /tmp/agent-prompt.md <<'EOF'
[full prompt here, with backticks / code blocks / etc.]
EOF

# One-shot launch — claude consumes the short argv instruction, which points it at the file
c11 send --workspace $WS --surface $SURF "cd /path && claude --dangerously-skip-permissions \"Read /tmp/agent-prompt.md and follow the instructions.\""
```

This is the default for orchestrated sub-agents. No polling, no sleep, no screen-scraping. Works regardless of how many other Claude Code surfaces are in the workspace.

### Fallback — polling the workspace `claude_code` status

When you need claude interactive first (e.g. to send follow-up messages over the course of the session) and can guarantee no sibling claude is running concurrently in the workspace, you can poll the sidebar status that the c11 claude PATH wrapper populates:

```bash
# Wait for claude to reach Idle before sending the prompt
until c11 list-status --workspace $WS 2>/dev/null | grep -q '^claude_code=Idle '; do sleep 1; done
c11 send --workspace $WS --surface $SURF "Read /tmp/prompt.md and follow the instructions."
```

Supported status values: `Idle` (prompt waiting), `Running` (processing a turn), `Needs input` (permission/dialog), plus opt-in verbose tool descriptions. Values are `TitleCase`. The trailing space in the grep anchors the match to just `Idle`.

> **Critical gotcha — workspace aggregation.** `c11 list-status` is workspace-scoped; `--surface` is silently ignored. The `claude_code=...` row reflects activity across **every** Claude Code surface in the workspace, not the one you're targeting. With two or more claudes running (orchestrator + sub-agent, planner + triage + impl, or any parallel review fan-out), the row never decisively reports `Idle` and the `until` loop deadlocks. Prefer the one-shot pattern above whenever any sibling claude is in flight. This gotcha is a known binary limitation (no surface-scoped agent-status query exists); there is no polling recipe that safely substitutes in the multi-claude case.

Additional notes on the polling signal:
- The signal only exists when claude was launched through c11's bundled PATH. A `claude` invocation that bypasses the PATH wrapper will not emit status. For sub-agents you orchestrate from inside a c11 surface this is almost always fine — the wrapper is the default for `claude` in that context.
- Other TUIs (codex, kimi, opencode, etc.) do **not** get an equivalent wrapper, by design. For those, agents self-report by calling `c11 set-metadata --key status --value idle` / `running` themselves, following instructions in the c11 skill file they load at session start. OpenCode additionally gets a bundled notification/status plugin (see below). If an agent hasn't been taught to self-report and has no plugin, you won't see status for them — that's expected.

**Do not** regex for `❯`, `> `, or `Welcome to Claude Code`. Those patterns drift across Claude Code releases and produce silent stalls when they miss (v2.1.114 dropped the box prompt and changed the banner, breaking every previous recipe). Use one-shot argv delivery, or poll the status row when it's safe to do so.

### Why this works only for Claude Code, and how OpenCode plugins fit

The claude PATH wrapper at `Resources/bin/claude` is a **grandfathered, Claude Code-specific concession** — c11 does not write to any TUI's persistent config, and will not install analogous PATH wrappers for codex, kimi, or opencode. The host is deliberately unopinionated about the terminal: c11 provides the surface, the socket, and the skill file; what an agent does with them is the agent's business.

For most TUIs, the skill-driven self-reporting path above is how status gets populated. **OpenCode is the exception**: it has a clean plugin API with reliable event hooks (`session.idle`, `permission.asked`, `session.status`, `session.error`), so c11 bundles a notification/status plugin that `c11 skill install --tool opencode` copies into `~/.config/opencode/plugins/`. The plugin auto-loads at OpenCode startup and calls `c11 notify` + `c11 set-metadata` on the same event triggers that the Claude Code wrapper handles. This gives OpenCode panes the same blue-ring + tab-highlight + Cmd+Shift+U workflow without any PATH wrapper or `opencode.json` modification.

## Per-agent launch quirks

`$C11_DEFAULT_AGENT_LAUNCH` (set in every c11 shell at spawn time) abstracts the launch command across agent types, so the main skill can teach one pattern that works for whichever agent the operator has chosen. The per-agent gotchas worth knowing before you spawn:

### claude-code

- **Wrapper on PATH.** Inside a c11 surface, `claude` resolves to `Resources/bin/claude`, a PATH-scoped wrapper that injects the session id and hook settings so the sidebar gets `claude_code` status. The launch command stored in `$C11_DEFAULT_AGENT_LAUNCH` always invokes this wrapper.
- **Never `claude -p`.** Headless mode breaks the auth chain; sub-agents cannot self-report. The default-agent resolver uses `claude --dangerously-skip-permissions`, which is the interactive form.
- **Multi-claude polling deadlock.** `c11 list-status` aggregates per workspace; a second claude in the same workspace makes the `claude_code` row never settle on `Idle`, deadlocking any `until ... grep Idle` poll. Use the one-shot argv pattern (Ready-state handoff above) when any sibling claude is in flight.

### codex

- **Use `codex --yolo`, not `codex exec`.** `codex exec` is headless and non-interactive, appropriate only for background jobs whose output will be read after completion. For a visible c11 surface where the operator should be able to watch or take over, `codex --yolo` is the right invocation.
- **No PATH wrapper.** codex does not get a c11 wrapper. The sub-agent self-reports sidebar status by calling `c11 set-status` / `c11 set-metadata` from its own lifecycle, following instructions in the c11 skill it loads at session start.

### grok

- **Use `grok --always-approve`.** Grok Build's auto-approve flag (parallel to claude's `--dangerously-skip-permissions` and codex's `--yolo`). TUI alias is `/yolo`. Headless mode is `grok agent` or `grok -p`; do not use either for a visible c11 surface.
- **Auth gotcha.** OIDC-acquired tokens (`grok login` browser flow) currently 403 at the chat endpoint for non-Heavy SuperGrok tiers. Use an `XAI_API_KEY` from console.x.ai instead; it bypasses the Heavy-only gate.
- **No PATH wrapper.** Status comes from skill-driven self-reporting, same as codex/opencode/kimi.

### opencode

- **Bundled notification plugin.** OpenCode has a clean plugin API (`session.idle`, `permission.asked`, `session.status`, `session.error`). `c11 skill install --tool opencode` copies a bundled plugin (`c11-notify.js`) into `~/.config/opencode/plugins/` that bridges these events into c11 notifications + sidebar status — same workflow as Claude Code's hooks. No PATH wrapper, no `opencode.json` modification.
- **No PATH wrapper.** Like codex, status comes from the plugin (if installed) or skill-driven self-reporting. If neither is set up, the sidebar won't show status for opencode; that is expected, not a bug.
- **Launch command is operator-configured** under Settings → Agents & Automation → Agent Launcher Button. The resolver materializes whatever the operator chose into `$C11_DEFAULT_AGENT_LAUNCH` at shell-spawn time. Preference changes only take effect on newly-spawned shells, not already-running ones.

### kimi, others

- **No PATH wrapper, no plugin.** Status comes from skill-driven self-reporting only. If an agent hasn't been taught to self-report, the sidebar won't show status for it; that is expected, not a bug.
- **Launch command is operator-configured** under Settings → Agents & Automation → Agent Launcher Button. The resolver materializes whatever the operator chose into `$C11_DEFAULT_AGENT_LAUNCH` at shell-spawn time.

### Banner-string scraping is always wrong

Do not regex `c11 read-screen` output for `❯`, `> `, `Welcome to Claude Code`, `Claude Code v`, or any other prompt or banner string. They drift across releases and produce silent stalls. Use one-shot argv delivery, or poll a status row when it is safe to do so.

## Agent-to-agent communication

Sub-agents can `c11 send` directly into each other's terminals — no orchestrator relay required.

```bash
c11 send --workspace workspace:N --surface surface:M "The number is 42"
```

This is a powerful primitive for handoffs: agent A finishes a step, writes its result to agent B's terminal.

Structured handoffs can also ride on the metadata blob — agent A writes `c11 set-metadata --workspace $WS --surface $B_SURF --json '{"handoff":{"from":"A","result":"..."}}'`, and agent B polls with `c11 get-metadata --key handoff`. Pull-on-demand only; there is no subscribe in v1.

## Sub-agent self-reporting

Because interactive `claude --dangerously-skip-permissions` preserves the auth chain, sub-agents can update the sidebar and the metadata blob directly:

```bash
c11 set-status task "3/5 complete" --icon "play.fill" --color "#00FF00"
c11 set-progress 0.6 --label "3/5 subtasks"
c11 log --source "agent-name" "Finished the data model step"

# Richer — canonical metadata keys light up sidebar chip and title bar.
# When refining title/description, check `c11 get-titlebar-state` first, keep the
# title short and distinct, and preserve the description's last-line `Lineage:` breadcrumb.
c11 set-metadata --json '{"role":"reviewer","status":"running","progress":0.6}'
c11 set-title "PR Review"
c11 set-description "Stage 2 of 3: running smoke tests on PR #42; next, edge-case audit.
Lineage: Login Button → Review sub-agent"
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

### Suppress only workers you own

Suppress at dispatch iff **you** will act on this worker's completion and recoverable
blockers — you launched it, you consume its result, you clear its ordinary blocks. Then the
operator's sidebar stays quiet while coordination happens one level down. When in doubt,
launch normal: never infer suppression from what the operator's orchestration setup probably
is. Every suppression transfers responsibility upward — to you, on both channels:

- **Completion.** Suppression removes the operator-facing stop signal, and polling for flags
  does not detect ordinary completion. Give the worker an explicit completion path back to
  you — a mailbox message, a metadata handoff key, or a final `c11 send` into your pane — and
  consume it.
- **Escalation.** A flag overrides suppression completely, at full visual strength, so a
  genuinely blocked worker still reaches both you and the operator. Put the contract in the
  launch prompt: *"Report completion and recoverable blockers to your parent. Raise a c11
  flag only when operator action is required."* Suppression without that instruction reads to
  a worker as a gag, and a worker that believes it has been gagged will sit blocked in
  silence.

```bash
c11 launch-agent --type claude-code --suppressed ...   # you own it, you sweep it
c11 suppress --surface $SURF                           # manual-launch path: right after creating the surface
c11 get-metadata --workspace $WS --surface $SURF | grep '^flag = '   # escalation check; completion arrives on the channel you assigned
```

`get-metadata` is the read for attention state — `flag = <reason>` and `suppressed = true`
appear only when set, and neither `tree` nor `get-titlebar-state` carries them.

## Writing c11-aware agent prompts

When spawning sub-agents in c11, include these as first-class instructions in the prompt:

1. **Self-identify immediately.** First action: `c11 identify` + `c11 get-titlebar-state` (to read any lineage the orchestrator pre-wrote) + `c11 rename-tab "<descriptive name>"` + `c11 set-description "<why this pane is open right now>"` + `c11 set-agent --type <tui> --model <model-id>`. An unnamed, undescribed, undeclared tab is an unidentifiable agent. If the orchestrator pre-named the tab, keep that name unless your role sharpened, and preserve the description's `Lineage:` line.
2. **Name every tab you create in both fields, not just the title.** Title is 2–3 words, role-first, and DISTINCT from its siblings — make the first word differ (`Lint Fixes`, `Routes Impl`, `SPA Plan`). Write `c11 set-description` alongside: a one-sentence "what this pane is doing right now" first, closed by a `Lineage: A → B → C` breadcrumb as the last line — description is mandatory, not an afterthought. Pass the parent title in the spawn prompt so the sub-agent can keep that breadcrumb accurate if it ever renames itself.
3. **Report at milestones** via `c11 set-metadata`, `c11 set-status`, `c11 set-progress`, `c11 log`. Interactive `claude --dangerously-skip-permissions` inherits the auth chain, so sub-agents can self-report. **When scope shifts** (new task, different file, pivot) refresh both title and description at the pivot, not at the end — keep the description's `Lineage:` breadcrumb accurate.
4. **Deliver complex prompts via temp files** — write to a file, tell the agent to read it. Avoids shell-escaping issues with `c11 send`.
5. **Do not make silent splits.** For multiple related outputs, prefer tabs over splits. Propose layouts when they would help; do not impose them.
6. **Read the room before reshaping it.** `c11 tree --json` gives pixel and percent coordinates for every pane — check whether a new split will fit before asking for one.
7. **Require a positive receipt for consequential work.** State the exact work item,
   cwd, head/base (when git-backed), mode, and return channel. Do not treat surface
   creation as proof that the child oriented successfully.
