# c11 Charter

Captured from the c11 feature-brainstorm dialogue, 2026-04-16. This document is the canonical record of what c11 is, what it becomes beyond the rename, and the initial feature scope. The rename-surface agent may decompose this into `docs/c11-identity.md` and updates to `ROADMAP.md` at its discretion.

---

## What c11 is

c11 is Stage 11's fork of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) — a native macOS terminal multiplexer for AI coding agents, built on Ghostty.

c11 is a **host and primitive**, not an intelligence layer. It gives agents and operators a great place to work: terminal, browser, markdown surfaces, workspaces, splits, tabs, notifications, and a scriptable CLI/socket API. The opinion about *what agents do* lives elsewhere — in Lattice, in Spike, in whatever tooling Stage 11 builds around c11.

### Three surface types

c11 ships three first-class surface types alongside each other:

1. **Terminal** — inherited from cmux/Ghostty, GPU-accelerated, agent-focused.
2. **Browser** — WKWebView-backed, scriptable automation API (agent-browser port), proxy-aware.
3. **Markdown** — renders markdown with Mermaid diagram support. Turns c11 into a natural host for agent-rendered docs, reports, and diagrams.

The three-surface story — *terminal + browser + markdown, all scriptable from a single CLI* — is the one-line pitch for the fork. Nothing else on the market offers this combination as a native macOS primitive.

## Division of labor: c11 ↔ Lattice

This is the critical architectural stance:

- **c11 does not integrate *into* Lattice, Spike, Cell Zero, or Mycelium.**
- **Lattice (and other Stage 11 tooling) integrates *into* c11** via the socket API and metadata primitives c11 exposes.

Every feature proposal passes this test: **"Does this *have* to live in c11, or could it live in Lattice and consume c11's API?"** If it could live upstairs, it should. The things that must live in c11 are the ones that inherently need AppKit, Ghostty, PTY, WKWebView, OS-level notifications, or sub-millisecond keystroke latency. Everything else belongs in the consumer.

This keeps c11's surface area small, its mutation cost low, and its identity clean.

## Distribution posture

- **Public fork, Stage 11 branded.** Lives on Stage 11's public GitHub, ships via homebrew tap (`stage11/c11` or similar).
- **Credit upstream.** Top of README acknowledges manaflow-ai/cmux as the origin; we are an explicit fork.
- **Regular upstream pulls.** Cadence TBD but not lazy — we want manaflow-ai's velocity on core terminal/browser work.
- **Upstream our general-purpose wins when appropriate.** Not everything stays in the fork — features that would benefit all cmux users (e.g., richer socket API for pane metadata) are good candidates to contribute back.
- **Keep Stage-11-specific opinions in the fork.** Branding, Spike/Lattice-tuned defaults, and anything that only makes sense inside Stage 11's world stays ours.

## Mutability posture

**No premature architecture.** We do not define a plugin system, a parallel Stage-11-only module, or an internal abstraction layer up front.

We ship the first few mutations by patching naturally where they belong. The *shape* of those mutations will teach us whether we need plugin seams or a parallel module. If the first five modules stay easy to merge with upstream, we keep patching. If they don't, we reach for a seam — but only then.

---

## MVP — eight modules

Listed in rough shipping order. None of these require new architectural concepts; each extends an existing cmux extensibility point.

### 1. TUI auto-detection

c11 identifies which agent TUI is running in each pane — Claude Code, Codex, Kimi, OpenCode as first-class supported agents.

- **Mechanism:** Process-tree heuristic (walks the PTY subtree, matches known binaries) as the default. Explicit declaration via CLI/env (`cmux set-agent --type claude-code --model claude-opus-4-7` or `CMUX_AGENT_TYPE=claude-code`) overrides the heuristic and can carry richer fields the heuristic can't know (model, task ID, Spike role). Declaration writes are sugar over `surface.set_metadata` — M1 does not introduce a new socket method.
- **Extends:** The existing `set_agent_pid` socket command and `Workspace.agentPIDs` storage. Today those only power stale-session detection; this module surfaces them everywhere.
- **Wraps into:** Module 3 (sidebar chips), Module 2 (canonical metadata keys).

### 2. Per-pane JSON metadata blob

Each pane can carry an open-ended JSON metadata object that agents can read and write over the socket.

- **New socket commands:** `surface.get_metadata`, `surface.set_metadata`, `surface.clear_metadata`. Wire format described in `skills/c11/references/metadata.md`.
- **Delivery model:** Pull-on-demand only. No pub/sub. Consumers query when they want the current state. (Push/subscribe is in the parking lot — add only if consumer count grows to justify it.)
- **Schema:** Fully open-ended body, with a small reserved namespace of canonical keys the sidebar can render when present: `role`, `status`, `task`, `model`, `progress`. Agents put anything else alongside these.
- **Consumers:** Lattice and future Stage 11 tooling. c11 stays a transport — it does not interpret the payload beyond rendering the canonical keys.
- **Extends:** Existing sidebar metadata (status pills, progress bars, logs) — additive, not replacing.

### 3. Sidebar TUI identity chip

Each pane's sidebar entry shows the detected-or-declared agent with a small icon + model label. Makes it instantly visible across ten panes which is Claude Opus vs Codex vs Kimi vs OpenCode — no need to read the title.

- **Source of truth:** Module 1 (auto-detection + declaration) plus the `model` canonical key from Module 2.
- **Rendering:** Inline in the existing vertical-tabs sidebar, next to branch/PR/port metadata.

### 4. Integration installers

`cmux install claude-code` (and equivalents for Codex, OpenCode, Kimi). Menubar item triggers the CLI command.

- Writes hooks into `~/.claude/settings.json`, Codex config, OpenCode config, etc.
- Shows a confirmation diff before writing (the TODO already scopes this).
- Installs the notification shims (OSC 9/99/777 + `cmux notify` wiring) and the agent-declaration command (Module 1).
- **Status:** Completely unimplemented today. This is the largest new build of the MVP.

### 5. Stage 11 brand identity

- Custom app icon aligned with the void/gold aesthetic from `company/brand/visual-aesthetic.md`.
- Custom bundle name (`c11`, bundle ID `com.stage11.c11`).
- Default color palette tuned for Stage 11 look. Users can still apply their own Ghostty terminal themes; the c11 default gives Stage 11 operators the intended look for free.

### 6. Markdown surface polish

The markdown surface type with Mermaid rendering is already merged to main. Remaining work is small polish:

- `--pane` flag for `cmux markdown` so the viewer can open inside an existing pane instead of always creating a new split.
- Any other small gaps that surface during use.

### 7. Prominent surface title bar

A full-width title bar across the top of every surface, always visible, holding a short title plus an optional longer description of what the surface is doing and why. Addresses the "ten panes in, which one is which?" problem: the sidebar tab title is often too short to carry real intent, and terminal scrollback gets lost.

- **Default behavior:** short title mirrors the sidebar tab title (same source — terminal OSC-set title, agent-declared, or user-set).
- **Expanded behavior:** a longer description can be set independently — an agent declares "Running smoke suite across 10 shards; reports to Lattice task lat-412" and the title bar shows it persistently.
- **Writers:** both the agent (via CLI / socket) and the user (inline edit or context menu) can set title bar content.
- **Storage:** lives in the per-surface JSON metadata blob (Module 2) under canonical keys `title` and `description`. No new storage primitive.
- **Visual:** spans the full width of the surface content area, single-line title with multi-line description collapsible/expandable. Height tuned so it doesn't steal meaningful terminal rows.

### 8. `cmux tree` overhaul (spatial layout)

The current `cmux tree` prints a hierarchical listing but doesn't convey **where** panes sit on screen. Agents need spatial awareness — total content area in pixels, each pane's position as both percentage and pixel ranges on the H (horizontal) and V (vertical) axes, and the split path that produced it. Without this, agents planning layouts or picking a target pane are blind.

- **Output layers:** (1) ASCII floor plan sized to the current workspace's content area, (2) hierarchical listing with H/V `[start,end]` percent AND pixel ranges per pane, (3) JSON coordinates when `--json` is set.
- **Default scope change:** `cmux tree` defaults to the current workspace (not current window). `--window`, `--workspace`, `--all` remain available as explicit overrides. Behavior change is noted as intentional — scripts that relied on window-default are expected to add an explicit flag.
- **Derivation:** pixel rects come from `vendor/bonsplit`; percentages are derived synchronously on main (`pane_H_pixel / workspace_content_width`, same for V). No new cache layer.
- **Tab lines:** each pane box carries a count of its tab surfaces and a single selected-tab line (truncated). Full tab list appears in the hierarchical listing.

---

## Parking lot — explicitly deferred

Named so they're recoverable without having to re-derive them. None of these are rejected; they're just not in the first wave.

### Layout intelligence
- Best-guess default placement for `cmux new-pane` when the agent provides no hints.
- Topology query API (pane tree, sizes, density, sibling counts) so agents can make informed layout decisions.
- Intent-level layout API: `cmux new-pane --intent parallel-agents --count 10` → c11 picks the shape (grid, tabs-of-grids, etc.).
- Auto-rebalancing — c11 reshapes bad layouts after the fact.

### Metadata delivery
- Push/subscribe delivery for pane metadata changes (`pane.broadcast.changed` events). Ship only if consumer count grows beyond what pull-on-demand serves well.
- Canonical JSON-broadcast writers shipped per TUI (wrappers/hooks that auto-populate canonical keys as each TUI runs). May not be needed if the integration installers from Module 4 handle this.

### Agent-to-agent coordination
- Pane-to-pane structured messaging (not just keystroke injection) — an agent in one pane sends a typed message to another, discoverable by role/tag.

### Notification intelligence
- Notification source/type labeling (per-TUI grammar: "Codex wants to run `rm -rf ...`" shown distinctly from "Claude is waiting for input").

### Markdown extensions
- Live-reload from a file path (agent writes the file, viewer updates).
- Inline image rendering beyond Mermaid (sixel/iTerm protocols).
- `cmux markdown --stdin` to pipe content directly into a new markdown surface.

### Human-facing observability
- How the operator tracks ten agents across ten panes beyond the existing ring/sidebar notification system. Not yet explored in dialogue.

---

## Open questions

- **Upstream pull cadence.** Weekly? Biweekly? On-signal? Not decided.
- **Homebrew tap name.** Probably `stage11/c11`; not confirmed.
- **Integration installer UX.** Menubar item + CLI command is decided; the exact confirmation-diff UX is not.
- **Branding specifics.** The Stage 11 visual aesthetic is canonical; the specific icon design and palette mapping for c11 are still open.

---

## What c11 is *not*

Explicitly, to keep scope honest:

- Not a Lattice task tracker. Lattice does that; c11 exposes primitives Lattice consumes.
- Not a Spike orchestrator. Spike lives upstream of c11.
- Not a Mycelium client. Mycelium is a separate layer; c11 is one of the surfaces it observes.
- Not a replacement for Ghostty. c11 uses libghostty and reads Ghostty config; it adds workspace/sidebar/browser/markdown on top.
- Not a general-purpose AI-agent platform. It's a terminal multiplexer with three surface types, tuned for Stage 11's agent work.
