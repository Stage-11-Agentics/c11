# C11-9: Reorganize Settings into sidebar pages

## Problem

The public Settings window is still organized as a long implementation-shaped scroll. App behavior, appearance, workspace/sidebar behavior, notifications, browser routing, input, shortcuts, automation, agent skills, data, and reset behavior sit beside each other with weak conceptual boundaries. That makes Settings harder to scan and harder to extend as c11 grows.

## Source of truth

- Inventory: `docs/settings-reorganization-research.md`
- IA/copy proposal: `docs/settings-reorganization-proposal.md`

## Desired direction

Rebuild Settings around a sidebar page model:

1. General
2. Appearance
3. Workspace & Sidebar
4. Browser
5. Notifications
6. Input & Shortcuts
7. Agents & Automation
8. Data & Privacy
9. Advanced

Group controls by the operator-facing conceptual model, not by `UserDefaults` keys or current implementation sections. The sidebar is the map. Risk and consequence copy live inside the relevant page, close to the control they affect.

## Voice and copy

- Use the hybrid c11 register: sidebar page titles in conventional Title Case; section headers short and concrete; helper text terse, c11-native, and consequence-oriented.
- Target the hyperengineer: use operator, agent, workspace, pane, surface, socket, skill, room.
- Avoid SaaS copy: user, AI assistant, manage, configure, streamline, empower.
- Theme slot labels should not be "Light Theme" / "Dark Theme". Use "When the system says day" and "When the system says night"; compact fallback: "system day" / "system night".

## Scope

- Replace the single-scroll Settings layout with sidebar navigation and the nine target pages.
- Move every currently visible public Settings control into the target page model from the proposal.
- Add page-local grouping: common, behavior, details, actions, advanced/risky where useful; avoid empty structure.
- Group the keyboard shortcut matrix by task area: Window, Navigation, Panes, Browser, Notifications, Terminal, TextBox, Help.
- Add local helper/consequence text only where it reduces uncertainty: socket modes, full open access, browser exceptions/HTTP allowlists, link interception, notification command, reset coverage, and external state not reset.
- Rename/reset copy so Reset All does not overpromise; prefer "Reset Settings" plus clear coverage and exceptions.
- Localize all user-facing strings per c11 policy.

## Out of scope

- Changing behavioral defaults unless explicitly approved in a follow-up.
- Debug-only Settings or hidden developer controls, except where reset/data boundaries make them user-visible.
- New Settings features beyond the IA/copy work, aside from small seams needed to render the reorganized pages cleanly.

## Acceptance criteria

- All current public Settings controls remain reachable.
- The Settings sidebar shows the nine pages in the proposed order.
- Theme slots use the day/night system-state copy.
- Appearance uses "c11 theme" for app chrome themes and does not imply Ghostty terminal themes are being changed.
- Browser routing and exception controls stay on Browser, with consequence text near link interception and HTTP/host exceptions.
- Agents & Automation clearly separates skill installation from socket access and keeps full open access behind confirmation.
- Data & Privacy distinguishes data leaving the machine, local browser data, reset settings, and external state not reset.
- Reset copy accurately describes what is reset and what is not, including browser history, socket password files, agent skill install state, and macOS notification permission where applicable.
- Shortcut remapping is grouped by task area and remains easy to scan.
- All new UI strings are localized.
- Tests, if added, exercise observable behavior or view/model seams. Do not add source-text or grep-style tests.

## Validation

Use a tagged c11 build for visual validation. Check that the Settings window is scannable at normal and narrow widths, helper text does not wrap into clutter, no control text clips, and every moved setting still reads/writes its existing preference or action.
