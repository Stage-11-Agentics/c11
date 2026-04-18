---
name: cmux
description: c11mux — Stage 11's native macOS terminal multiplexer built as infrastructure for the Spike. Use when (1) session starts inside c11mux (env var CMUX_SHELL_INTEGRATION=1), (2) creating pane splits, surfaces, or workspaces, (3) sending text or commands to another surface, (4) launching or orchestrating sub-agents in sibling panes, (5) declaring agent identity or writing the surface manifest, (6) reading surface contents or spatial layout via `cmux tree`, (7) setting surface title or description, (8) reporting progress via sidebar status/log/progress, (9) using the embedded browser for web validation (preferred over Chrome MCP when inside c11mux), (10) any cmux-specific command or troubleshooting question. Auto-load whenever c11mux is detected in the environment.
---

# c11mux

**c11mux** is Stage 11's fork of [cmux](https://github.com/manaflow-ai/cmux), a macOS-native reinterpretation of `tmux` rebuilt on [Ghostty](https://ghostty.org). The lineage matters: tmux ergonomics — panes, splits, persistent sessions — land as first-class AppKit surfaces, and the terminal underneath is a GPU-accelerated renderer, not a font-pushing TTY widget.

**c11mux is infrastructure for the [Spike](https://stage11.ai/spike).** The spike is the compound actor — human:digital, operator:model — a human navigating a shifting capability surface as a single entity. c11mux is the room that actor works in.

The goal is narrow and deliberate: be best-in-class for the hyper-engineer — the operator running extensive terminal-based LLM coding agents in parallel — and for the agents themselves. Wherever the work happens. Terrestrial, orbital, or elsewhere — the interface is the same. That is who this tool is for. Everything else is scaffolding.

c11mux is not an intelligence layer. The opinion about what agents *do* lives upstairs — Lattice, Mycelium, the rest of the Stage 11 stack. c11mux is host and primitive: terminal, browser, and markdown surfaces; workspaces, panes, tabs; notifications; one CLI and socket API for every seam. The binary is `cmux`. The app is `c11mux`. Commands below use the binary name.

## Detect c11mux

Check `CMUX_SHELL_INTEGRATION`. If set to `1`, you are inside c11mux; use native workflows (splits, embedded browser, `cmux set-metadata`) instead of Chrome MCP or plain `open`.

```bash
[ "$CMUX_SHELL_INTEGRATION" = "1" ] && echo "in c11mux" || echo "not in c11mux"
```

Other env vars available to child processes: `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, `CMUX_TAB_ID`, `CMUX_SOCKET_PATH`, `CMUX_SOCKET_PASSWORD`. The spawning shell may also set `CMUX_AGENT_TYPE`, `CMUX_AGENT_MODEL`, and `CMUX_AGENT_TASK` to pre-seed agent declaration — read once at surface start.

## Concepts

- **Window** — top-level macOS window
- **Workspace** — sidebar tab (title, git branch, cwd, ports, notifications)
- **Pane** — split region within a workspace
- **Surface** — terminal, browser, or markdown viewer inside a pane. Panes can hold multiple surfaces as tabs.

Refs accept UUIDs, short refs, or indexes: `window:1`, `workspace:1`, `pane:2`, `surface:3`, `tab:1`.

## Orient first

At session start — always, in this order:

```bash
cmux identify                                              # Your workspace/surface/pane refs (JSON)
cmux tree                                                  # Spatial layout of the current workspace + hierarchical listing
cmux set-agent --type claude-code --model claude-opus-4-7  # Declare terminal_type + model (mandatory)
cmux rename-tab "<your role>"                              # Name your own tab before anything else
```

Also populate `role`, `task`, and `status` via `cmux set-metadata` **if known** from the opening message or environment (e.g. the user references a ticket ID, or `CMUX_AGENT_TASK` is set). Skip when unknown — don't guess.

**An unnamed tab is an unidentifiable agent.** Name your tab immediately, even when working solo. Key word first, 2–4 words, under 25 characters (the sidebar truncates from the right): `cmux rename-tab "TICKET-42 Plan"` survives; `"Planning TICKET-42"` truncates to `"Planning TICK…"`.

**If the user's opening message is absent or ambiguous, ask before orienting.** This aligns with the global "dialogue" norm — don't silently rename a tab `"Explore"` just to have something in the sidebar. A direct request ("fix this bug", "what is X called") is not ambiguous; proceed with the request and run orientation in the same turn.

### Declaring your agent (details)

`cmux set-agent` writes the canonical `terminal_type` and `model` keys so the sidebar, title bar, and `cmux tree` output all know what kind of agent you are.

```bash
cmux set-agent --type claude-code --model claude-opus-4-7
cmux set-agent --type codex --task lat-412
```

Supported `--type` values include `claude-code`, `codex`, `kimi`, `opencode`. Any kebab-case string is accepted for unrecognized agents — the sidebar will render a generic chip.

If c11mux's integration was installed for your TUI via `cmux install <tui>`, the declaration fires automatically at every session start. Call it anyway — `set-agent` is idempotent and guards against the integration not being installed.

You can also declare via env vars set in the spawning shell: `CMUX_AGENT_TYPE`, `CMUX_AGENT_MODEL`, `CMUX_AGENT_TASK`. Read once at surface start.

## The surface manifest

Every surface carries a **surface manifest** — an open-ended JSON document that declares what the surface is, what it's doing, and anything else agents or tools want to advertise about it. Agents read and write it over the socket via `cmux get-metadata` / `cmux set-metadata`. c11mux renders a small set of canonical keys in the sidebar and title bar, and leaves every other field opaque for Lattice, Mycelium, and third-party tools to define their own keyspace on top.

Think of the manifest as the extension point for c11mux: the host provides the surface and the transport; anyone can stake out their own keys.

```bash
# Write
cmux set-metadata --json '{"role":"reviewer","task":"lat-412","progress":0.4}'
cmux set-metadata --key status --value "running" 
cmux set-metadata --key progress --value 0.6 --type number

# Read
cmux get-metadata                       # full blob
cmux get-metadata --key role --key task
cmux get-metadata --sources             # include provenance (who wrote each key, when)

# Clear
cmux clear-metadata --key task
cmux clear-metadata                     # clear everything (explicit source only)
```

**Canonical keys** (typed, rendered, size-capped):

| Key | Type | Renders |
|-----|------|---------|
| `role` | string (kebab-case, ≤64) | sidebar label |
| `status` | string (≤32) | sidebar pill |
| `task` | string (≤128) | sidebar monospace tag |
| `model` | string (kebab-case, ≤64) | sidebar chip |
| `progress` | number 0.0–1.0 | sidebar progress bar |
| `terminal_type` | kebab-case string (≤32) | sidebar chip |
| `title` | string (≤256) | title bar + sidebar tab label |
| `description` | markdown subset (≤2048) | title bar expanded region |

Non-canonical keys are free-form — the blob is your app's transport. Per-surface cap is 64 KiB; pull-on-demand only (no subscribe in v1).

**Precedence**: `explicit > declare > osc > heuristic`. `cmux set-metadata` writes as `explicit` and always wins. Heuristic auto-detection never overwrites a declared or explicit value.

## Targeting

`--workspace` and `--surface` must be passed **together** when targeting a surface you don't live in. Either flag alone fails or misfires.

```bash
# WRONG — errors or hits the wrong surface
cmux send --surface surface:5 "npm test"

# RIGHT — always pass both when remote
cmux send --workspace workspace:2 --surface surface:5 "npm test"
cmux send-key --workspace workspace:2 --surface surface:5 enter
```

When talking to your own surface, omit both — env vars default them correctly.

## Send text to a surface

```bash
cmux send "echo hello"                  # Types text — does NOT submit
cmux send-key enter                     # Send a keypress directly
```

**Gotcha**: `\n` is stripped when `cmux send` is called from Claude Code's Bash tool. Always pair `send` with a separate `send-key enter`:

```bash
cmux send --workspace $WS --surface $SURF "your command"
cmux send-key --workspace $WS --surface $SURF enter
```

For complex prompts (backticks, code blocks, multi-line), deliver via temp file and tell the receiving agent to `Read /tmp/prompt.md` — shell escaping through `cmux send` is brittle.

## Read another surface

```bash
cmux read-screen --workspace $WS --surface $SURF --lines 80
cmux read-screen --scrollback --lines 200       # include scrollback buffer
```

## Create splits, panes, surfaces

```bash
cmux new-split <left|right|up|down>            # Split current pane (terminal only)
cmux new-pane --type browser --url <url>       # New browser pane
cmux new-surface --pane <pane-ref>             # Add a tab to an existing pane
```

`new-split` defaults to the **caller's** pane; `new-surface` defaults to the **focused** pane (often different). To add a tab to your own pane, read `caller.pane_ref` from `cmux identify` and pass it via `--pane`.

## Spatial layout (cmux tree)

`cmux tree` is how an agent sees the room. By default it scopes to your current workspace, renders an ASCII floor plan sized to the real content area, and lists every pane with pixel and percent ranges on the H (horizontal) and V (vertical) axes plus the split path that produced it.

```bash
cmux tree                               # current workspace with floor plan (default)
cmux tree --window                      # all workspaces in current window (pre-M8 default)
cmux tree --all                         # every window
cmux tree --json                        # structured coordinates for layout reasoning
cmux tree --no-layout                   # suppress the floor plan, keep hierarchy
```

Read `cmux tree` before planning layouts — splitting blind leads to cramped panes. For programmatic layout decisions use `--json`: every pane carries its rect in pixels and percent, the workspace content-area dimensions, and its split path.

## Title and description

The title bar on every surface shows a short title plus an optional longer description of what the surface is doing and why. Both are writable by agent or user and live on the surface manifest (canonical `title` / `description` keys).

```bash
cmux set-title "SIG Delegator — reviewing PR #42"
cmux set-description "Running smoke suite across 10 shards; reports to Lattice task lat-412."
cmux set-title --from-file /tmp/title.txt    # for long or special-character titles
cmux get-titlebar-state                      # read caller's own title/description/collapsed state
```

`cmux rename-tab` is a thin alias for `set-title`. The sidebar tab label is a truncated projection of the title; the title bar shows the full string and, when expanded, renders the description as markdown (bold, italic, inline code, lists, headings, blockquotes, links, rules; images/fenced-code/tables are stripped at render; links are styled but not navigable). Content over ~5 lines scrolls internally in a 90pt-capped region. See [references/metadata.md](references/metadata.md#title--description-sugar-m7) for the full subset and payload fields.

## Sidebar reporting

Sidebar metadata commands give fast feedback without touching the JSON blob:

```bash
cmux set-status task "3/5 complete" --icon "play.fill" --color "#00FF00"
cmux set-progress 0.6 --label "3/5 subtasks"
cmux log --source "agent-name" "Finished the data model step"
cmux list-status
cmux clear-status task
```

**Constraint**: these only work from a direct c11mux child process. Headless `claude -p` subprocesses are reparented to `launchd` and lose the auth chain — they cannot call any `cmux` command. Interactive `cc` keeps the chain intact.

## Launching sub-agents

Use **`cc`** (the `--dangerously-skip-permissions` alias) — never bare `claude` or `claude -p`:

- `claude -p` (headless) breaks the auth chain; sub-agents can't self-report.
- Plain `claude` stalls on permission approvals.
- `cc` in an interactive pane inherits c11mux env vars, preserves the auth chain, and skips approvals. Sub-agents can `cmux set-status`, `cmux log`, `cmux set-progress` freely.

Standard launch: create the pane, launch `cc`, poll for the prompt, name the tab, send the task as two calls (`send` then `send-key enter`). See [references/orchestration.md](references/orchestration.md) for the full pattern with ready-state polling, tab-naming conventions, and agent-to-agent handoffs.

## Web validation

When in c11mux, prefer the embedded browser over Chrome MCP (`mcp__claude-in-chrome__*`). It is lighter, integrated into the workspace, and does not create stray Chrome windows.

- Preview: `open <url>` or `open <file>` — reuses the browser surface automatically.
- Interact: `cmux browser click`, `cmux browser snapshot`, `cmux browser fill`, etc.

Reach for Chrome MCP only when **not** in c11mux or when a Chrome-specific feature is required. See the `cmux-browser` sibling skill for the full automation API.

## References

- **[references/api.md](references/api.md)** — full command surface: addressing, discovery, workspace/pane/surface management, surface initialization quirks, sidebar metadata, notifications, troubleshooting
- **[references/orchestration.md](references/orchestration.md)** — multi-agent patterns: layout, tab naming, launching `cc` sub-agents, agent-to-agent communication, sidebar reporting, writing cmux-aware prompts
- **[references/metadata.md](references/metadata.md)** — metadata deep dive: socket methods, precedence table, all canonical keys, sidecar sources, consumer patterns
- **[../cmux-browser/SKILL.md](../cmux-browser/SKILL.md)** — cmux embedded browser automation
- **[../cmux-markdown/SKILL.md](../cmux-markdown/SKILL.md)** — markdown surface viewer

Working with Lattice tickets inside c11mux? Also consult the `lattice` skill for Lattice+c11mux integration patterns.
