# Settings Reorganization Proposal

Status: proposal  
Scope: public Settings window only. Debug-only controls stay out unless they affect reset, data, or operator safety.

## Goal

Settings should be fast to scan, easy to extend, and legible to the hyperengineer running many surfaces at once.

The sidebar is the map. Pages are grouped by conceptual model, not implementation storage. Risk and consequence live inside the relevant page, close to the setting they affect.

The full inventory of current controls lives in `docs/settings-reorganization-research.md`. This document defines the target information architecture and copy direction.

## Voice

Use the hybrid c11 register:

- Sidebar page titles use conventional title case for scanability.
- Section headers stay short and concrete.
- Helper text is terse, c11-native, and consequence-oriented.
- Prefer: operator, agent, workspace, pane, surface, socket, skill, room.
- Avoid: user, AI assistant, manage, configure, streamline, empower.

Helper text appears only where it reduces uncertainty. Settings is not the place for maximal poetry; it should feel like c11 because it names the room precisely.

### Theme Copy

Do not label the two c11 theme slots as "Light Theme" and "Dark Theme" in the UI. Use system-state language instead:

- When the system says day
- When the system says night

This keeps the control understandable while moving it closer to the Stage 11 voice. If a more compact label is needed, use "system day" and "system night."

## Sidebar Pages

1. General
2. Appearance
3. Workspace & Sidebar
4. Browser
5. Notifications
6. Input & Shortcuts
7. Agents & Automation
8. Data & Privacy
9. Advanced

Use this order as the default. It starts with app-wide basics, moves through the operator's visible room, then reaches automation, data, and lower-level controls.

## Page Pattern

Each page should follow the same internal rhythm where it applies:

1. Common
2. Behavior
3. Details
4. Actions
5. Advanced or risky controls

Not every page needs every group. Avoid empty structure. Do not move every risky setting to Advanced; a setting belongs where the operator will look for it. Put consequence text near the control.

## Pages

### General

App-wide behavior that does not belong to a specific surface type.

Likely groups:

- Language
- Quit behavior
- App telemetry

Helper text:

> choose the app-level defaults that travel with the room.

Notes:

- Move c11 theme selection to Appearance.
- Move notification behavior to Notifications.
- Move command palette behavior to Input & Shortcuts.
- Keep telemetry here if it is framed as an app-wide default; also cross-reference it from Data & Privacy.

### Appearance

Visual styling for c11 chrome, workspace colors, and sidebar tint.

Likely groups:

- c11 theme
- Workspace color indicator
- Workspace palette
- Sidebar tint

Helper text:

> tune the room without touching terminal themes.

Notes:

- Use "c11 theme" in user-facing copy.
- Use "when the system says day" and "when the system says night" for the two system appearance theme slots.
- Keep Ghostty terminal theme concerns out of this page unless a future setting explicitly bridges them.

### Workspace & Sidebar

How workspaces appear, move, and reveal status.

Likely groups:

- Workspace behavior
- Sidebar detail
- Sidebar metadata
- Pull request and link affordances

Helper text:

> decide how much signal the sidebar carries while agents work.

Notes:

- "Reorder on notification" belongs here but needs consequence text because it affects spatial memory.
- "Open Sidebar PR Links in c11 Browser" can live here because the operator discovers it through the sidebar.
- Keep surface, pane, workspace, and tab vocabulary consistent. Do not vary terms for prose texture.

### Browser

Search, routing, embedded browser behavior, import prompts, and web exceptions.

Likely groups:

- Search
- Browser appearance
- Link routing
- Host rules
- Import

Helper text:

> choose which web work stays inside c11.

Notes:

- HTTP allowlist and external URL patterns should stay on Browser, not Advanced.
- Place exceptions under a lower "Security & Exceptions" group.
- Link interception settings need consequence text: they change where terminal and sidebar actions land.

### Notifications

How c11 interrupts, marks unread work, and emits external signals.

Likely groups:

- In-app signals
- System signals
- Sound
- Command

Helper text:

> decide what gets to interrupt the operator.

Notes:

- Notification command needs local consequence text: it runs a shell command when notifications fire.
- Keep signal and styling distinct. Pane rings and flashes are notification signals, not general appearance.

### Input & Shortcuts

TextBox input, command palette behavior, shortcut hints, and shortcut remapping.

Likely groups:

- TextBox input
- Command palette
- Shortcut hints
- Keyboard shortcuts

Helper text:

> shape the keys that move through the room.

Notes:

- Group the shortcut matrix by task: Window, Navigation, Panes, Browser, Notifications, Terminal, TextBox, Help.
- Keep shortcut recording close to the action labels. Do not make the operator decode implementation keys.

### Agents & Automation

Agent skills, socket access, Claude Code integration, and automation-facing setup.

Likely groups:

- Agent skills
- Socket access
- Agent integrations

Helper text:

> agents can drive c11 once they know the room.

Notes:

- Socket modes need progressive disclosure and clear blast radius.
- Keep full open access behind confirmation.
- Skill installation copy should make filesystem writes explicit without turning into a warning wall.
- Prefer "agent" and concrete tool names such as Claude Code, Codex, Kimi, and OpenCode. Avoid "AI assistant."

### Data & Privacy

Telemetry, browser history, reset behavior, local files, and external state boundaries.

Likely groups:

- Data leaving the machine
- Local browser data
- Reset settings
- External state not reset

Helper text:

> clear local traces and choose what leaves the machine.

Notes:

- Reset All currently overpromises. Prefer "Reset Settings" plus a coverage summary.
- Browser history belongs here as a destructive data action, even if Browser also links to it.
- macOS notification permission, agent skill install state, socket password files, and browser history need explicit reset-boundary copy if they are not reset.

### Advanced

Low-frequency controls that affect plumbing or recovery.

Likely groups:

- Ports
- Socket password file
- Recovery and diagnostics
- Legacy or compatibility controls

Helper text:

> low-level controls for ports, sockets, and recovery paths.

Notes:

- Advanced is not a dumping ground.
- A setting only moves here when its primary mental model is implementation, compatibility, or recovery.
- If a control is risky but discoverable through a specific page, keep it on that page and label the consequence locally.

## Progressive Disclosure

Use progressive disclosure for controls that create cognitive load or carry a clear consequence:

- Socket modes beyond c11-only access.
- Full open socket access.
- Browser host exceptions and HTTP allowlists.
- Notification command.
- Reset coverage.
- External state that c11 cannot or should not reset.

Disclosure should be local and concrete. Prefer one line of consequence text over long explanatory paragraphs.

## Future-Proofing Rules

When adding a new Settings page:

- Add it to the sidebar only when it owns a stable concept the operator can name.
- Prefer extending an existing page when the setting changes behavior inside that page's domain.
- Keep implementation details out of page names.
- Do not use Advanced as a holding area for unfinished IA.

When adding a new setting:

- Put it where the operator would look before reading docs.
- Label the object first, then the behavior.
- Use the c11 primitive name if one exists.
- Add helper text only when the consequence is not obvious from the label and control.
- If the setting affects automation, data leaving the machine, focus, routing, or spatial stability, say so nearby.
