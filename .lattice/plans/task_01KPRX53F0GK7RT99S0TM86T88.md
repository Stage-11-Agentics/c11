# C11-5: Workspace sidebar cards: stable names first, agent details second

## Problem

In the current/latest c11 build, the sidebar workspace card can make the workspace name hard to read once an agent such as GPT-5 declares identity/status metadata. The card currently competes between workspace identity and agent/surface details. The workspace name should be the stable anchor.

## Desired direction

- The top line of every workspace card should always show the full workspace name.
- Default workspace names should be `Workspace 1`, `Workspace 2`, `Workspace 3`, etc.
- Agent identity/status details should not obscure or visually outrank the workspace name.
- The card may take more vertical room. There usually are not many workspaces, so readability and hierarchy matter more than maximum density.

## Discovery/design work

Before implementation, inventory the workspace-level parameters c11 can currently set or render, including workspace title/name, cwd, git branch/dirty state, ports, notifications/unread state, active surface or tab identity, surface metadata/status rollups, and any socket/CLI-set workspace fields. Use that inventory to decide which values belong directly on the workspace card, which belong under expanded details, and which should stay out of the sidebar.

## Acceptance criteria

- Workspace card hierarchy is explicit: first line is always the workspace name and remains readable with agent metadata present.
- Newly created default workspaces use `Workspace N` naming instead of terminal-oriented defaults.
- The ticket outcome includes a concise map of all workspace-level parameters and where each should render.
- Sidebar card layout is allowed to become taller if that materially improves scanability.
- User-facing strings are localized per c11 policy.
- Any tests added verify observable behavior or built-app artifacts, not source-text snippets.

## Notes

This came from current dogfooding: GPT-5 identity/status text made it hard to read the workspace name. Treat this as a small UI polish item with a short design pass before code.
