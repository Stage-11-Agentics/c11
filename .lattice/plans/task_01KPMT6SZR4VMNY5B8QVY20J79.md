# CMUX-36: Bottom status bar + Jump-to-Latest-Unread as first tenant

Introduce a persistent bottom status bar across c11mux window chrome. Ship with a single first tenant: a clickable "Jump to Latest Unread" button in the bottom-left that calls the existing `AppDelegate.jumpToLatestUnread()`.

## Motivation

Upstream cmux shipped Cmd+Shift+U / "Jump to Latest Unread" (blog: https://cmux.com/blog/cmd-shift-u). The behavior is **already inherited and live in c11mux** — wired through `KeyboardShortcutSettings.Action.jumpToUnread`, exposed in the View menu, Notifications menu, status bar menu, titlebar notifications popover, and `NotificationsPage`. But every existing affordance is either a keyboard shortcut or buried behind a menu / popover. A big, always-visible push-button on the main chrome would:

- Teach users the shortcut exists (visible key hint in the button).
- Give a one-click fallback when hands aren't on the keyboard.
- Provide an at-a-glance unread count via badge.

## Scope — bottom status bar primitive

This is tenant #1 of a new **general-purpose bottom status bar**. The bar itself is the primary deliverable; the notifications button is the first thing it carries.

- New persistent footer view attached to the main window chrome. Height ~22–28pt, ordinary macOS status-bar aesthetic.
- Designed as a multi-slot container (leading, center, trailing regions). Future tenants (active-agents count, daemon/port health, CPU, app version, update state) can slot in without revisiting layout.
- Must respect split/workspace layout — bar is window-scoped, not pane-scoped.
- Must survive fullscreen, traffic-light hidden, and sidebar collapsed states.
- Localized strings only (`String(localized:)` — per project policy). No bare literals.
- Follows typing-latency-sensitive guardrails in `CLAUDE.md` (no `@EnvironmentObject`/`@ObservedObject` churn that would force body re-eval on keystrokes).

## First tenant: Jump-to-Latest-Unread button

Lives in the **leading** slot (bottom-left). Behavior:

- On click: call `AppDelegate.shared?.jumpToLatestUnread()` — exact parity with Cmd+Shift+U. No new semantics.
- **Always visible.** Disabled / dimmed when unread count is zero; enabled when >= 1.
- **Badge** shows unread count (e.g., "3") when > 0. Hidden or "0" when empty.
- Tooltip surfaces the current keyboard shortcut from `KeyboardShortcutSettings.Action.jumpToUnread` (reuse `.safeHelp(...)` pattern at `Sources/NotificationsPage.swift:117`).
- Label/icon: TBD in design — bell icon + "Jump to unread" text + badge is a reasonable first pass.

## Out of scope / explicitly not changing

- No change to `jumpToLatestUnread()` logic.
- No change to the titlebar notifications popover (`Sources/Update/UpdateTitlebarAccessory.swift`) — that stays as the full list + mark-all-read surface. Bottom button is the one-click jump affordance; popover is the management surface.
- No sequential-step-through-unreads behavior. "Next" in the user's framing = "latest unread," same as Cmd+Shift+U.
- No new tenants in this ticket (agent counts, ports, version). Those get their own tickets once the bar exists.
- No redesign of the existing notifications model or ordering.

## Key source references

- `Sources/AppDelegate.swift:8826` — `jumpToLatestUnread()` (the function the button calls).
- `Sources/Update/UpdateTitlebarAccessory.swift:1008` — existing "Jump to Latest" button; mirror its binding pattern (read unread count from notification store, enable/disable accordingly).
- `Sources/TerminalNotificationStore.swift` — source of truth for unread state.
- `Sources/KeyboardShortcutSettings.swift` — `Action.jumpToUnread` for tooltip rendering.
- `Sources/NotificationsPage.swift:117` — `.safeHelp(KeyboardShortcutSettings.Action.jumpToUnread.tooltip(...))` pattern.

## Acceptance

- Bottom status bar is visible on every c11mux window by default.
- Button appears in bottom-left with correct icon + label + badge.
- Clicking it jumps to the latest unread exactly as Cmd+Shift+U does today.
- Badge updates reactively as unread count changes.
- Button is disabled/dim when no unread.
- Fullscreen, split, sidebar-collapsed, and multi-window states all render the bar cleanly.
- Typing latency unchanged (verify against debug event log; do not subscribe to stores that would thrash during typing).

## Review pack

Triple-force plan review expected before implementation (per project default `plan_review_mode: triple`).
