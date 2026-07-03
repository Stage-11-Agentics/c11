---
name: c11
version: 1
description: c11 is a native macOS terminal multiplexer. Load this skill anytime any of the following attributes are hit: (1) session is inside c11 (`C11_SHELL_INTEGRATION=1`), (2) working with panes, surfaces, workspaces, splits, or tabs, (3) sending text or commands to another surface, (4) launching or orchestrating sub-agents, (5) declaring agent identity, setting title/description, or reporting sidebar status, (6) using the embedded browser or markdown surfaces, (7) any c11-specific command or troubleshooting question. When in doubt, load it.
---

# c11

**c11** is a native macOS terminal multiplexer for the operator:agent pair. One operator runs many agents in parallel; c11 gives every terminal, browser, and markdown surface a handle so the whole field stays legible. Hierarchy: **window → workspace (a sidebar tab) → pane (a split region) → surface (a terminal, browser, or markdown viewer)**.

This card is deliberately short. It covers **orientation** — the one thing every agent does on launch — and a **map** of everything else. Load the named reference when you reach for a capability; don't pull in depth you don't need.

## Detect c11

`C11_SHELL_INTEGRATION=1` means you're inside c11 — prefer native workflows (splits, the embedded browser, `c11 set-metadata`) over Chrome MCP or plain `open`. Other env vars available to child processes: `C11_WORKSPACE_ID`, `C11_SURFACE_ID`, `C11_TAB_ID`, `C11_SOCKET_PATH`. The spawn path may also pre-seed `C11_AGENT_TYPE`, `C11_AGENT_MODEL`, `C11_AGENT_TASK`.

Refs accept UUIDs, short refs, or indexes: `workspace:1`, `pane:2`, `surface:3`, `tab:1`.

**Where new work goes:** a new **pane** when the work wants its own spatial slot (a sub-agent, a log tail, a browser for validation); a new **surface** when a pane just wants another tab; a new **workspace** when the operator names a different project or mission. Default to one workspace per project unless the operator's setup says otherwise.

## Boot fast, orient lazily

On launch you have no task yet — the operator's opening message is usually just "load the skill" or similar context-only text. Don't spend their time deliberating over a mechanical identity ritual; that dead-time before you can even take a task is the single biggest way an agent wastes the operator's first half-minute. **Get reachable in one cheap step, report ready, and let the rest fill in as you work.**

At launch, run exactly this — as one batched shell call, at minimal effort, no per-command deliberation:

```bash
c11 set-agent  --surface "$C11_SURFACE_ID" --type "$C11_AGENT_TYPE" --model "$C11_AGENT_MODEL"
c11 rename-tab --surface "$C11_SURFACE_ID" "Awaiting first task"
```

Then reply in one line that you're ready for the task. That is the whole launch. `set-agent` puts the right chip in the sidebar; the placeholder title marks the tab as a live-but-unassigned agent. If `$C11_AGENT_TYPE` / `$C11_AGENT_MODEL` are empty you were launched outside the wrapper — substitute your own known type and model, don't guess.

**Orient the rest lazily** — when you get a real task or first touch the workspace (any split / status / pane op), and not before:

- `c11 rename-tab` to your real 2–4 word role, and `c11 set-description` to why the surface is open right now (definitions below). The sidebar is the operator's only view into a room of parallel agents, so retitle off the placeholder as your first action once a task lands — a working agent must not sit under "Awaiting first task".
- `c11 tree` when you actually need the spatial layout; `c11 identify --json` for your refs if you didn't capture them (footgun below).
- Read the reference for whatever capability you reach for (map below) — not preemptively.
- **Declare a stable mailbox address** if peers will reach you: `c11 set-metadata --surface "$C11_SURFACE_ID" --key mailbox.address --value "<stable-handle>" --type string`. Titles are mutable and renames silently re-partition the bus; a declared address survives them. (Depth → [docs/c11-mailbox-guide.md](../../docs/c11-mailbox-guide.md).)

> **Footgun — pass `--surface` explicitly on surface- or tab-scoped writes.** The CLI defaults a missing `--surface` to whatever surface the *operator* is currently focused on — usually a peer agent's tab in a multi-surface workspace — so an omitted flag silently writes to the wrong surface. Every surface exports `$C11_SURFACE_ID` (inherited by subprocesses), so `--surface "$C11_SURFACE_ID"` targets you correctly; if it ever reads empty, capture your refs once from `c11 identify --json` and pass the literal `surface:<n>` instead (robust on any build). Apply this to every surface/tab write (`set-metadata`, `set-agent`, `set-title`, `set-description`, `rename-tab`, `clear-metadata`, `trigger-flash`). Verify the first write with `c11 get-titlebar-state --surface <surface>` against the surface marked `◀ here` in `c11 tree --no-layout`.

### Title vs description, and lineage

- **Title = what the surface *is*** — generic, reusable. A filename for file-backed surfaces (`PHILOSOPHY.md`); a role for terminals (`Phase 2 agent`, `Log tail`).
- **Description = why it's open *right now*** — one or two sentences of current context the operator can read without opening the surface.
- **Refresh both when scope shifts** (plan → impl, ticket → ticket, file → file) — at the pivot, not at session end.
- **Lineage for downstream panes:** chain parent → child with `::` in the title (`Login Button :: MA Review :: Claude`) and lead the description with a `Lineage:` breadcrumb. **Sibling** workers the operator drives directly are *not* downstream — use plain anchors (`Feature Left`, `Lattice Manager`), no chain. Before renaming, check `c11 get-titlebar-state`; if a chain exists, preserve the prefix and refine only the trailing segment.

## What c11 can do — load the reference when you need it

| You want to… | Load |
|---|---|
| split / create / resize panes & surfaces, `tree`, `send`, `read-screen`, targeting, `--cwd` | [references/api.md](references/api.md) |
| launch sub-agents, the tab-naming convention, layout patterns, write c11-aware prompts | [references/orchestration.md](references/orchestration.md) |
| send/receive inter-agent messages (the mailbox) | [docs/c11-mailbox-guide.md](../../docs/c11-mailbox-guide.md) |
| surface-manifest depth, sidebar reporting (`set-status` / `set-progress` / `log`), flash, precedence & sources | [references/metadata.md](references/metadata.md) |
| workspace persistence, snapshots, the conversation store & resume | [references/conversation.md](references/conversation.md) |
| the Claude session-resume hook | [references/claude-resume.md](references/claude-resume.md) |
| drive the embedded browser (validate UI without leaving c11) | [c11-browser skill](../c11-browser/SKILL.md) |
| open markdown surfaces with live reload | [c11-markdown skill](../c11-markdown/SKILL.md) |

A few cross-cutting rules worth knowing before you reach for those:

- **`send` / `set-status` / `log` take their text as a trailing positional, not `--text`.** `c11 send --surface <s> "npm test"`. Writing `--text "…"` types the literal string `--text` into the terminal.
- **`send` / `send-key` require explicit targeting.** Pass `--workspace` and `--surface` *together* when the target isn't your own surface; `--window` alone is not enough.
- **Socket/CLI commands never steal macOS focus**, and telemetry commands run off-main — don't expect a `send` to raise a window.
- **`send` reaches PTYs only.** It cannot drive AppKit/SwiftUI controls (the text box, settings, sidebar, find overlay). For those, ask the operator or use accessibility automation.

## Editing this skill

It installs as a **one-time copy** under `~/.claude/skills/c11/`; the app does not track the repo source after install. After any source edit, run `scripts/sync-installed-skills.sh c11` or the live copy agents load stays stale. This is the skill-editing equivalent of `reload.sh` after a code change.

## Troubleshooting

If `c11` on PATH isn't the active bundle's CLI, run `c11 doctor` (`--json` for machine-readable). It reports the bundled CLI path, how `c11` resolves on PATH, and a `status` of `ok | mismatch | missing | no_bundle`.

Working Lattice tickets inside c11? Also load the `lattice` skill for the integration patterns.
