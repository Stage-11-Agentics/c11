---
name: c11
version: 1
description: c11 — Stage 11's native macOS terminal multiplexer built as infrastructure for the Spike. Use when (1) session starts inside c11 (env var CMUX_SHELL_INTEGRATION=1), (2) creating pane splits, surfaces, or workspaces, (3) sending text or commands to another surface, (4) launching or orchestrating sub-agents in sibling panes, (5) declaring agent identity or writing the surface manifest, (6) reading surface contents or spatial layout via `c11 tree`, (7) setting surface title or description, (8) reporting progress via sidebar status/log/progress, (9) using the embedded browser for web validation (preferred over Chrome MCP when inside c11), (10) any c11-specific command or troubleshooting question. Auto-load whenever c11 is detected in the environment.
---

# c11

**c11** is Stage 11's fork of [cmux](https://github.com/manaflow-ai/cmux), a macOS-native reinterpretation of `tmux` rebuilt on [Ghostty](https://ghostty.org). The lineage matters: tmux ergonomics — panes, splits, persistent sessions — land as first-class AppKit surfaces, and the terminal underneath is a GPU-accelerated renderer, not a font-pushing TTY widget.

**c11 is infrastructure for the [Spike](https://stage11.ai/spike).** The spike is the compound actor — human:digital, operator:model — a human navigating a shifting capability surface as a single entity. c11 is the room that actor works in.

The goal is narrow and deliberate: be best-in-class for the hyperengineer — the operator running extensive terminal-based LLM coding agents in parallel — and for the agents themselves. Wherever the work happens. Terrestrial, orbital, or elsewhere — the interface is the same. That is who this tool is for. Everything else is scaffolding.

c11 is not an intelligence layer. The opinion about what agents *do* lives upstairs — Lattice, Mycelium, the rest of the Stage 11 stack. c11 is host and primitive: terminal, browser, and markdown surfaces; workspaces, panes, tabs; notifications; one CLI and socket API for every seam. The binary is `c11`. The app is `c11`.

The binary is `c11`. Commands below use that name.

## Detect c11

Check `CMUX_SHELL_INTEGRATION`. If set to `1`, you are inside c11; use native workflows (splits, embedded browser, `c11 set-metadata`) instead of Chrome MCP or plain `open`.

```bash
[ "$CMUX_SHELL_INTEGRATION" = "1" ] && echo "in c11" || echo "not in c11"
```

Going forward `C11_SHELL_INTEGRATION=1` is also set alongside the legacy `CMUX_SHELL_INTEGRATION` marker; either variable is a valid detection signal.

Other env vars available to child processes: `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, `CMUX_TAB_ID`, `CMUX_SOCKET_PATH`, `CMUX_SOCKET_PASSWORD`. The spawning shell may also set `CMUX_AGENT_TYPE`, `CMUX_AGENT_MODEL`, and `CMUX_AGENT_TASK` to pre-seed agent declaration — read once at surface start. `C11_*` variants are the primary names going forward; the `CMUX_*` names continue to work via dual-read.

## Concepts

- **Window** — top-level macOS window
- **Workspace** — sidebar tab (title, git branch, cwd, ports, notifications)
- **Pane** — split region within a workspace
- **Surface** — terminal, browser, or markdown viewer inside a pane. Panes can hold multiple surfaces as tabs.

Refs accept UUIDs, short refs, or indexes: `window:1`, `workspace:1`, `pane:2`, `surface:3`, `tab:1`.

## Orient first

At session start — always, in this order:

```bash
c11 identify                                                    # Your workspace/surface/pane refs (JSON)
c11 tree                                                        # Spatial layout of the current workspace + hierarchical listing
c11 set-agent --type claude-code --model claude-opus-4-7        # Declare terminal_type + model (mandatory)
c11 rename-tab --surface "$CMUX_SURFACE_ID" "<your role>"       # Name your own tab before anything else
```

> **Binary bug (as of 2026-04-18):** `CMUX_TAB_ID` is exported equal to the workspace UUID, not the tab UUID. Bare `c11 rename-tab "<role>"` (and any other tab-scoped command that defaults to `CMUX_TAB_ID`) errors with `not_found: Tab not found`. Always pass `--surface "$CMUX_SURFACE_ID"` for tab-scoped commands (`rename-tab`, `set-title`, `set-description`) until this is fixed — `CMUX_SURFACE_ID` itself is correct.

Also populate `role`, `task`, and `status` via `c11 set-metadata` **if known** from the opening message or environment (e.g. the user references a ticket ID, or `CMUX_AGENT_TASK` is set). Skip when unknown — don't guess.

**An unnamed tab is an unidentifiable agent.** Name your tab immediately, even when working solo. Key word first, 2–4 words, under 25 characters (the sidebar truncates from the right): `c11 rename-tab "TICKET-42 Plan"` survives; `"Planning TICKET-42"` truncates to `"Planning TICK…"`.

**Show lineage for downstream tabs.** When a pane is spawned from another — sub-agents under an orchestrator, review agents over a feature's work, follow-ups rooted in earlier output — chain parent to child with `::`, parent first: `Login Button :: MA Review :: Claude`. Multiple rungs chain in order. The sidebar truncates to the parent (grouping siblings visibly); the full chain shows in the title bar. Users may override; lineage is the default whenever a parent exists. Before renaming, check `c11 get-titlebar-state` — if a chain is already present, preserve the prefix and only refine the trailing segment. See [references/orchestration.md#tab-naming-mandatory](references/orchestration.md#tab-naming-mandatory) for the full convention.

**Sibling workers are not downstream.** When the operator sets up peer panes they'll drive directly — e.g., two Claude Code panes for parallel feature work, a standing "Lattice Manager" next to them — skip the `::` chain and use a short positional or role anchor: `Feature Left`, `Feature Right`, `Lattice Manager`. Reserve `::` lineage for true hierarchical orchestration where a parent agent routes work down to sub-agents it will read back from.

**If the user's opening message is absent or ambiguous, ask before orienting.** This aligns with the global "dialogue" norm — don't silently rename a tab `"Explore"` just to have something in the sidebar. A direct request ("fix this bug", "what is X called") is not ambiguous; proceed with the request and run orientation in the same turn.

### Declaring your agent (details)

`c11 set-agent` writes the canonical `terminal_type` and `model` keys so the sidebar, title bar, and `c11 tree` output all know what kind of agent you are.

```bash
c11 set-agent --type claude-code --model claude-opus-4-7
c11 set-agent --type codex --task lat-412
```

Supported `--type` values include `claude-code`, `codex`, `kimi`, `opencode`. Any kebab-case string is accepted for unrecognized agents — the sidebar will render a generic chip.

If c11's integration was installed for your TUI via `c11 install <tui>`, the declaration fires automatically at every session start. Call it anyway — `set-agent` is idempotent and guards against the integration not being installed.

You can also declare via env vars set in the spawning shell: `CMUX_AGENT_TYPE`, `CMUX_AGENT_MODEL`, `CMUX_AGENT_TASK`. Read once at surface start.

## The surface manifest

Every surface carries a **surface manifest** — an open-ended JSON document that declares what the surface is, what it's doing, and anything else agents or tools want to advertise about it. Agents read and write it over the socket via `c11 get-metadata` / `c11 set-metadata`. c11 renders a small set of canonical keys in the sidebar and title bar, and leaves every other field opaque for Lattice, Mycelium, and third-party tools to define their own keyspace on top.

Think of the manifest as the extension point for c11: the host provides the surface and the transport; anyone can stake out their own keys.

```bash
# Write
c11 set-metadata --json '{"role":"reviewer","task":"lat-412","progress":0.4}'
c11 set-metadata --key status --value "running" 
c11 set-metadata --key progress --value 0.6 --type number

# Read
c11 get-metadata                        # full blob
c11 get-metadata --key role --key task
c11 get-metadata --sources              # include provenance (who wrote each key, when)

# Clear
c11 clear-metadata --key task
c11 clear-metadata                      # clear everything (explicit source only)
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

**Precedence**: `explicit > declare > osc > heuristic`. `c11 set-metadata` writes as `explicit` and always wins. Heuristic auto-detection never overwrites a declared or explicit value.

## Targeting

`--workspace` and `--surface` must be passed **together** when targeting a surface you don't live in. Either flag alone fails or misfires.

```bash
# WRONG — errors or hits the wrong surface
c11 send --surface surface:5 "npm test"

# RIGHT — always pass both when remote
c11 send --workspace workspace:2 --surface surface:5 "npm test"
c11 send-key --workspace workspace:2 --surface surface:5 enter
```

When talking to your own surface, omit both — env vars default them correctly.

## Send text to a surface

```bash
c11 send "echo hello"                   # Types text — does NOT submit
c11 send-key enter                      # Send a keypress directly
```

**Gotcha**: `\n` is stripped when `c11 send` is called from Claude Code's Bash tool. Always pair `send` with a separate `send-key enter`:

```bash
c11 send --workspace $WS --surface $SURF "your command"
c11 send-key --workspace $WS --surface $SURF enter
```

For complex prompts (backticks, code blocks, multi-line), deliver via temp file and tell the receiving agent to `Read /tmp/prompt.md` — shell escaping through `c11 send` is brittle.

**PTY-only reach.** `c11 send` / `c11 send-key` write bytes into the target terminal surface's PTY. They do NOT dispatch NSEvents to the AppKit responder chain, so they cannot drive non-terminal UI — the TextBox input, settings panels, sidebar controls, find overlays, and any SwiftUI / AppKit control are all unreachable this way. If a task requires typing into or clicking an AppKit element, the c11 socket CLI is the wrong tool. Working alternatives:

- Ask the human operator to exercise the UI and paste back the result.
- Accessibility automation (`AXUIElement`, `System Events` AppleScript).
- A purpose-built debug socket command in the c11 app itself (e.g. add a `textbox.focus` or `textbox.send-key` handler to the socket).

Surface this constraint up front when planning — don't sink time into PTY-based automation for a target that isn't a terminal.

## Read another surface

```bash
c11 read-screen --workspace $WS --surface $SURF --lines 80
c11 read-screen --scrollback --lines 200        # include scrollback buffer
```

## Create splits, panes, surfaces

```bash
c11 new-split <left|right|up|down>             # Split any pane; the NEW pane is always a terminal
c11 new-pane --type browser --url <url>        # New pane of any surface type; --direction is relative to focus
c11 new-surface --pane <pane-ref>              # Add a tab to an existing pane
```

- **`new-split` clarified.** Source can be a pane of any surface type — terminal, browser, or markdown. Only the *new* pane is constrained to terminal. Use `new-pane` when the new pane should be a browser or markdown viewer.
- **Direction is relative to the focused pane.** `new-pane` has no `--pane` flag; it operates on the currently focused pane. Call `c11 focus-pane --pane <ref> --workspace <ref>` first if you need to target a different one.
- **`new-split` does NOT return the new pane ref** — output is `OK surface:<N> workspace:<M>` only. Follow with `c11 tree --no-layout` (or `--json`) to discover the newly created pane. `new-pane` *does* return the pane ref (`OK surface:<N> pane:<P> workspace:<M>`).
- **Default targets differ.** `new-split` defaults to the **caller's** pane; `new-surface` defaults to the **focused** pane (often different). To add a tab to your own pane, read `caller.pane_ref` from `c11 identify` and pass it via `--pane`.

## Resize panes

Binary splits aren't balanced automatically. Two `new-split right` calls give you `[A 50% | B 25% | C 25%]`, not equal thirds. Use `resize-pane` to rebalance.

```bash
c11 resize-pane --pane <ref> --workspace <ref> (-L|-R|-U|-D) --amount <px>
```

- `-R <px>` grows the pane by pushing its **right** border rightward (shrinks the right neighbor).
- `-L <px>` grows the pane by pushing its **left** border leftward (shrinks the left neighbor).
- `-U` / `-D` are the vertical equivalents.
- A direction toward the workspace edge fails with `Pane has no adjacent border in direction <dir>`: the leftmost pane cannot `-L`, the topmost cannot `-U`, etc. Resize from the neighbor instead.

**Compound-split cascade.** When you resize a pane whose nearest matching border belongs to an *outer* split (not the split that directly separates it from its closest sibling), the resize moves the outer boundary; both children of the inner split grow **proportionally**, preserving their existing ratio. Example: given `[A 50%] | [B 25% | C 25%]` (outer horizontal split, right half split again), `resize-pane --pane B -L 500` pulls 500px across the outer boundary — B and C each gain 250px because their inner ratio is 1:1. Resize again across the inner boundary (`-R` on B) to equalize B and C without touching A.

**Recipe: equal thirds from two right-splits.** After `new-split right` twice on a workspace of width `W`, you have `[A W/2 | B W/4 | C W/4]`. One resize lands thirds, because the cascade does the inner redistribution for free:

```bash
# W = workspace content width (read from `c11 tree --json` or the ASCII floor plan header)
c11 resize-pane --workspace $WS --pane $B -L $((W / 6))
# → A shrinks by W/6 to W/3; B and C each grow by W/12 (inner ratio preserved) to W/3 each.
```

## Spatial layout (c11 tree)

`c11 tree` is how an agent sees the room. By default it scopes to your current workspace, renders an ASCII floor plan sized to the real content area, and lists every pane with pixel and percent ranges on the H (horizontal) and V (vertical) axes plus the split path that produced it.

```bash
c11 tree                                # current workspace with floor plan (default)
c11 tree --window                       # all workspaces in current window (pre-M8 default)
c11 tree --all                          # every window
c11 tree --json                         # structured coordinates for layout reasoning
c11 tree --no-layout                    # suppress the floor plan, keep hierarchy
```

Read `c11 tree` before planning layouts — splitting blind leads to cramped panes. For programmatic layout decisions use `--json`: every pane carries its rect in pixels and percent, the workspace content-area dimensions, and its split path.

## Title and description

The title bar on every surface shows a short title plus an optional longer description of what the surface is doing and why. Both are writable by agent or user and live on the surface manifest (canonical `title` / `description` keys).

```bash
c11 set-title "SIG Delegator — reviewing PR #42"
c11 set-description "Running smoke suite across 10 shards; reports to Lattice task lat-412."
c11 set-title --from-file /tmp/title.txt     # for long or special-character titles
c11 get-titlebar-state                       # read caller's own title/description/collapsed state
```

`c11 rename-tab` is a thin alias for `set-title`. The sidebar tab label is a truncated projection of the title; the title bar shows the full string and, when expanded, renders the description as markdown (bold, italic, inline code, lists, headings, blockquotes, links, rules; images/fenced-code/tables are stripped at render; links are styled but not navigable). Content over ~5 lines scrolls internally in a 90pt-capped region. See [references/metadata.md](references/metadata.md#title--description-sugar-m7) for the full subset and payload fields.

### The title + description split

Given the naming rule above (and its sub-agent echo in [orchestration.md](references/orchestration.md#writing-c11-aware-agent-prompts)), the useful further distinction is *what* title and *what* description. They carry different weight:

- **Title = what the surface *is*.** Generic and reusable across sessions. For file-backed surfaces (markdown, browser-on-local-file) the filename alone is usually right: `PHILOSOPHY.md`, `RFC-42.md`, `staging.yaml`. For role-holding terminals, the role in 2–4 words: `Phase 2 agent`, `Log tail`, `gh pr watch`.
- **Description = why this surface is open *right now*.** Context-specific, one to two sentences. The operator glancing at the sidebar and expanding the title bar should understand what prompted this surface and what to pay attention to, without reading the content.

```bash
c11 set-title       --workspace $WS --surface $SURF "PHILOSOPHY.md"
c11 set-description --workspace $WS --surface $SURF "Reviewing after migrating the observe-from-outside principle out of memory into this doc. About to revise the Primitives-before-policy section."
```

The operator is running parallel work and context-switching between surfaces; title + description together make the sidebar a navigable index of in-flight work instead of a list of opaque tabs. A hyperengineer who can see "why is this open" at a glance is strictly more effective than one who has to re-read the content to remember.

**Batch with the open command.** When you `c11 new-pane --type markdown --file …` or `--type browser --url …` for the operator, set title + description as the immediate next calls — don't defer. A surface that lives even briefly without a description is one the operator will have to re-derive context for when they tab over.

**Multiple artifacts in one session → one pane, not many tabs.** If the work produces more than one markdown artifact for the operator to review, consolidate them: either append to a single trail file with sections, or add subsequent files as **tabs of the same pane** with `c11 new-surface --type markdown --file <path> --pane <pane-ref>`. Three top-level markdown tabs make the operator do navigation work c11 is supposed to remove. See the c11-markdown skill's *Producing artifacts the operator will return to* section for the full pattern.

### Lineage in titles and descriptions

For panes spawned downstream of another — sub-agents, reviews, fixes rooted in earlier output — lineage goes in **both** fields:

- **Title** chains with `::`, parent first (see Orient first above). Each segment stays short so the full chain fits: `Login Button :: MA Review :: Claude`.
- **Description** carries the story up the chain. Lead with a breadcrumb line, then the current context.

```bash
c11 set-title       --workspace $WS --surface $SURF "Login Button :: MA Review :: Claude"
c11 set-description --workspace $WS --surface $SURF "Lineage: Login Button → Multi-Agent Review → Claude reviewer.
Reviewing PR #42 for correctness, style, and edge cases. One of three parallel reviewers; findings merge upstream."
```

When updating the description on task change, preserve the lineage line — don't strip it. It's the operator's map for reconstructing why this pane exists; losing it forces a re-derivation from content.

### Pane-layer lineage

Panes (the split-tree leaves a surface lives in) carry their own free-form JSON manifest alongside the surface manifest. It surfaces the same title/description pair, and the same `::` lineage convention applies — the rules documented above cover panes verbatim, so this section only notes what's pane-specific.

- **Write with `--pane`.** `c11 set-metadata --pane <pane-ref> --key title --value "Parent :: Child"` (or `--json '{...}'`) writes to the pane layer. `--surface` and `--pane` are mutually exclusive on the same call.
- **Read-then-write is the default.** `pane.set_metadata` returns `prior_values` for every key in the incoming partial. Compose from the prior value rather than replacing — chain a new rung onto the existing lineage instead of blowing it away, unless the new task is genuinely unrelated.
- **Same `::` rules as surface titles.** Parent first, short segments, sibling workers skip the chain (see the *Orient first* and *Lineage in titles and descriptions* sections above — don't duplicate conventions across layers). When you `--title "Parent :: Child"` on `c11 new-split` / `new-pane`, the seeded value flows through the same persistence path as an explicit write.
- **On `/clear` (context reset), ask before renaming.** An agent that drops context inherits the pane title it had before the reset. If the next task is unrelated, ask the operator whether to rename the pane rather than silently replacing the breadcrumb — the prior lineage was load-bearing for someone. c11 installs no `/clear` hook; this is guidance, not automation.

## Sidebar reporting

Sidebar metadata commands give fast feedback without touching the JSON blob:

```bash
c11 set-status task "3/5 complete" --icon "play.fill" --color "#00FF00"
c11 set-progress 0.6 --label "3/5 subtasks"
c11 log --source "agent-name" "Finished the data model step"
c11 list-status
c11 clear-status task
```

**Constraint**: these only work from a direct c11 child process. Headless `claude -p` subprocesses are reparented to `launchd` and lose the auth chain — they cannot call any `c11` command. Interactive `claude` keeps the chain intact.

## Launching sub-agents

Use **`claude --dangerously-skip-permissions`** — never bare `claude` (stalls on approvals) or `claude -p` (headless, breaks the auth chain):

- `claude -p` (headless) breaks the auth chain; sub-agents can't self-report.
- Plain `claude` stalls on permission approvals.
- `claude --dangerously-skip-permissions` in an interactive pane inherits c11 env vars, preserves the auth chain, and skips approvals. Sub-agents can `c11 set-status`, `c11 log`, `c11 set-progress` freely.

> **`claude` on PATH is the c11 wrapper.** Inside a c11 surface, `claude` resolves to `Resources/bin/claude` — a PATH-scoped wrapper that injects session-id and hook settings so the sidebar gets `claude_code` status. `cc` is **not** a c11-provided command; some operators set `alias cc='claude --dangerously-skip-permissions'` in their shell config, but you cannot assume it exists. Always invoke `claude --dangerously-skip-permissions` explicitly in anything you send to a pane.

For **Codex** in a visible c11 surface, launch the interactive TUI with `codex --yolo`, not `codex exec`. `codex exec` is headless/non-interactive and is only appropriate for background jobs whose output will be read after completion; it is the wrong tool when the operator should be able to watch, inspect, or take over the agent in c11.

```bash
c11 send --workspace $WS --surface $SURF "cd /path && codex --yolo \"Read /tmp/lat-xxx-prompt.md and follow the instructions.\""
c11 send-key --workspace $WS --surface $SURF enter
```

**Preferred launch — one-shot prompt via claude argv.** Write the prompt to a file first, then launch `claude --dangerously-skip-permissions` with a short positional argument that tells it to read the file. It boots and submits the initial message in one step, so there is no ready-state race to solve:

```bash
# 1. Stage the prompt (complex content → file; shell escaping in `c11 send` is brittle)
cat > /tmp/lat-xxx-prompt.md <<'EOF'
[full prompt here]
EOF

# 2. One-shot launch
c11 send --workspace $WS --surface $SURF "cd /path && claude --dangerously-skip-permissions \"Read /tmp/lat-xxx-prompt.md and follow the instructions.\""
c11 send-key --workspace $WS --surface $SURF enter
```

This is the default pattern for all orchestrated sub-agent launches. No polling, no sleep, no screen-scraping.

**Two-call launch — only when you need to interact post-boot.** Launch `claude --dangerously-skip-permissions` bare, wait for the sidebar `claude_code` status to hit `Idle` (the c11 claude wrapper emits it), then send additional input:

```bash
c11 send --workspace $WS --surface $SURF "cd /path && claude --dangerously-skip-permissions"
c11 send-key --workspace $WS --surface $SURF enter
until c11 list-status --workspace $WS 2>/dev/null | grep -q '^claude_code=Idle '; do sleep 1; done
c11 send --workspace $WS --surface $SURF "Read /tmp/prompt.md and follow the instructions."
c11 send-key --workspace $WS --surface $SURF enter
```

> **Multi-claude gotcha:** `c11 list-status` is **workspace-scoped**; `--surface` is silently ignored. The `claude_code=Running|Idle` row reflects activity across every Claude Code surface in the workspace, not the one you're targeting. With two or more claudes running in the same workspace (the common orchestration case — planner + triage + impl, or orchestrator + sub-agent), the row never decisively reports `Idle` and the `until` loop deadlocks. Prefer the one-shot pattern above when any sibling claude is in flight. Polling is only safe when your target is the sole claude in the workspace.

**Never screen-scrape `c11 read-screen` for `❯`, `> `, `Welcome to Claude Code`, `Claude Code v`, or any other banner string** — those drift across Claude Code releases and fail silently. See [references/orchestration.md](references/orchestration.md) for the full pattern including tab-naming conventions and agent-to-agent handoffs.

## Web validation

When in c11, prefer the embedded browser over Chrome MCP (`mcp__claude-in-chrome__*`). It is lighter, integrated into the workspace, and does not create stray Chrome windows.

- Preview: `open <url>` or `open <file>` — reuses the browser surface automatically.
- Interact: `c11 browser click`, `c11 browser snapshot`, `c11 browser fill`, etc.

Reach for Chrome MCP only when **not** in c11 or when a Chrome-specific feature is required. See the `c11-browser` sibling skill for the full automation API.

### Opening a browser pane on a local service

If the browser pane targets a local daemon (e.g. `lattice dashboard`, a dev server), start the daemon **before** creating the browser pane — otherwise the browser loads an error page and won't auto-refresh when the service comes up later. If you do have to open the pane first, reload it once the listener is live:

```bash
c11 browser --surface <surface> reload
```

**Don't pipe daemon launches to `head`, `tail`, or any finite reader.** When the reader exits, the daemon gets SIGPIPE and dies mid-start. Detach cleanly instead:

```bash
nohup lattice dashboard --port 8799 > /tmp/lattice-dashboard.log 2>&1 &
disown
```

## References

- **[references/api.md](references/api.md)** — full command surface: addressing, discovery, workspace/pane/surface management, surface initialization quirks, sidebar metadata, notifications, troubleshooting
- **[references/orchestration.md](references/orchestration.md)** — multi-agent patterns: layout, tab naming, launching Claude Code sub-agents, agent-to-agent communication, sidebar reporting, writing c11-aware prompts
- **[references/metadata.md](references/metadata.md)** — metadata deep dive: socket methods, precedence table, all canonical keys, sidecar sources, consumer patterns
- **[../c11-browser/SKILL.md](../c11-browser/SKILL.md)** — c11 embedded browser automation
- **[../c11-markdown/SKILL.md](../c11-markdown/SKILL.md)** — markdown surface viewer

Working with Lattice tickets inside c11? Also consult the `lattice` skill for Lattice+c11 integration patterns.
