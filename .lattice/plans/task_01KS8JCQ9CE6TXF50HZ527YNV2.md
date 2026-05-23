# C11-115: New-workspace sheet redesign: recents-as-panel, letter-cell layout icons, 2x3 layout, pin/keyboard/drag-drop/empty-state, last-layout memory

## Goal

Overhaul the New Workspace dialog to give power users a richer, more spatially scannable starting point. Recents becomes a first-class panel with rich per-row metadata; blueprints get letter-labeled cells so users can read them at a glance; several power-user affordances thread through (pin/keyboard/drag-drop/empty-state, last-layout memory).

Branch from origin/main @ 5fc161aaa62a8528ca176a0a45741e47e4aa9473.

## Scope

### Recents-as-panel (replaces dropdown)
- Always-visible, vertically scrollable list. ~6 rows in viewport.
- Per-row: project name, full path (mono dim), last opened, open count, pin star.
- Pinned rows lock to top regardless of sort.
- Sort toggle (Most recent / Most opened) in footer.
- Click selects. Double-click or Return opens immediately with last layout.
- Arrow keys navigate when focus not in input.
- Drag a folder from Finder to set base directory.
- Empty state for fresh installs.
- Store cap raised from 8 to 50.
- Data model: RecentDirectory { path, lastOpenedAt, openCount, pinned }. Migrate from existing string-array UserDefaults.

### Base directory block
Merged: directory path + Browse at top, 'or select from your recent directories:' caption, then list.

### Workspace name field
Preserved between recents block and Default layouts. Placeholder syncs with directory's last-path-segment.

### Default layouts row (horizontal scroll)
- Five layouts: Single, Two columns, Three columns, 2x2, **2x3 (new)**.
- Horizontal scroll; 5th item intentionally clipped.
- Each icon: grid of cells with letter labels. First cell A, rest T. Selection only changes outline/background; icon interior stays calm.
- Legend below: A agent / T terminal / B browser / M markdown.

### Custom blueprints row (no letters in v1)
- Horizontal scroller. Outlined topology icons, name, 'N panes' meta.
- '{N} blueprints' count below.
- 'i' help icon opens popover with agent-first framing + 'Reveal blueprints folder' button.

### Single-selection across both rows
Clicking any layout deselects every other blueprint.

### Footer copy
'Launch your default coding agent in the first pane'.

### Last-selected layout memory
One global UserDefaults key. Falls back to Two columns when unset.

## Out of scope
- Type-aware letter labels on custom blueprints.
- Inline filter/search.
- Already-open indicator.
- Git branch/dirty markers.
- Cmd-click for new window.

## Mock
/tmp/c11-new-workspace-mock.html (operator-reviewed).

## Validation plan
- Sheet opens with new layout.
- Click/dblclick/Return on rows behave correctly.
- Pin/unpin holds across sort modes.
- Arrow keys navigate; typing in inputs doesn't steal nav.
- Drag-folder-from-Finder sets directory.
- Empty state visible after clearing UserDefaults.
- 2x3 creates 6 panes (2 cols x 3 rows).
- Letter cells render correctly for defaults.
- Default-layout selection persists across reopens.
- Popover + Reveal-folder works.
