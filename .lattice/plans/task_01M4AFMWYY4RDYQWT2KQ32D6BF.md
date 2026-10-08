# C11-356: drag-panel-to-split rejects panel:N refs, ignores --workspace, and steals focus

## Symptom
An agent working inside c11 1.0.0 (132) on 2026-10-06 hit two problems with one command:
1. `c11 drag-panel-to-split --panel panel:48 down` fails with `ERROR: Surface not found`. The same command with the panel's UUID works.
2. When it succeeds, it moves in-app focus to the new area. That breaks the socket focus policy: only explicit focus commands may change focus.

## Cause (read on origin/main, not yet reproduced in a test)
- **CLI** (`CLI/c11.swift`, `case "drag-panel-to-split"`): the panel ref is resolved only when `client.scopedWindow != nil`. Otherwise the raw `panel:48` string goes straight into the v1 `drag_surface_to_split` command. `--workspace` is parsed and then dropped in the same branch, so without `--window` it is silently ignored.
- **Socket** (`TerminalController.dragSurfaceToSplit`): `resolveSurfaceId(from:workspace:)` accepts only a UUID or an integer index, not a `panel:N` short ref. With no workspace option it targets `legacyWorkspaceTarget(workspaceId: nil)`, the selected workspace. That means a panel in a background workspace fails even by UUID, and an integer index silently names a panel in whatever workspace the operator is looking at.
- **Focus**: `bonsplitController.splitPane(orientation:movingTab:insertFirst:)` focuses the new pane, and the handler never restores the prior focus.

## Fix
- Resolve `--panel` (refs, UUIDs, indexes) and `--workspace` in the CLI on every path, not only under `--window`. Better still, route the command through a v2 method that takes explicit workspace and panel UUIDs, like the other area commands. Default the workspace to the caller's own (`C11_WORKSPACE_ID`), never the selected one.
- Preserve focus: capture the focused area and panel before the split and restore them afterwards, unless a future explicit `--focus` flag asks otherwise. Move-into-split is a layout command, not a focus-intent command.
- Audit the sibling v1 commands that share `resolveSurfaceId` and `legacyWorkspaceTarget` for the same short-ref and selected-workspace behavior, and fix or list them in this ticket.

## Acceptance
1. From a panel in a background (non-selected) workspace, `c11 drag-panel-to-split --panel panel:N down` succeeds using the short ref, a UUID, or `--workspace`. It never touches the selected workspace.
2. After the move, `c11 identify --json` shows the same focused panel as before, and no `workspace.selected` event is emitted.
3. A socket test (`tests_v2/`) against a tagged build covers the short ref, the background workspace and focus preservation. The skill's api reference is updated if usage changes, and the skills are synced.
