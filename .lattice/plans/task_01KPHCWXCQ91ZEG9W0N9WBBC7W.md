# CMUX-10: Flash the sidebar tab selector, not just the pane — themable flash colors

## Problem

Today `cmux trigger-flash --surface <ref>` flashes only the pane content in-place. When the surface is in a non-focused workspace or tab, the flash is invisible — defeating the purpose of "hey, look here." The sidebar tab selector for that workspace/surface should flash too.

## Asks

1. **Sidebar tab flash.** When `trigger-flash` fires for a surface, also flash the corresponding sidebar tab item (the row representing that workspace / tab). Treat the flash as an addressable attention signal across ALL representations of that surface, not just the pane's content rect.
2. **Themable flash colors.** The flash color should be a theme-addressable attribute. Default could continue to be the current tone, but a `C11muxTheme` schema key like `flash.color` (and potentially `flash.sidebarColor` if we want them to differ) lets themes override it. Consider `$workspaceColor`-based defaults once the theme engine lands.

## Context

- Discovered during a conversation about building a c11mux theming engine. See `docs/c11mux-theming-plan.md` (in-flight via a cc agent in `surface:50`).
- Ties directly into the broader theming effort: flash is one more chrome attribute that wants to be theme-driven.

## Suggested relationship

This should be marked `related_to` the theming epic once that ticket is created by the planning agent. Depends on the theme engine foundation (M1) if flash color becomes a theme key; the sidebar-flash behavior itself can land independently.

## Non-goals

- Don't flash the Ghostty terminal content; that's Ghostty's cell rendering. Flash is a chrome-level signal.
- Don't flash the macOS window frame / traffic lights.
