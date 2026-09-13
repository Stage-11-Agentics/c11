# C11-228: Workspace deselection does not reliably throttle its selected surface

## Problem

Lifecycle `active ↔ throttled` is driven only from `TerminalPanelView`
(`.onAppear` / `.onChange(of: isVisibleInUI)`). A deselected workspace's subtree
lives in `AppKitHiddenWrapper` (hidden `NSHostingController`), whose SwiftUI body
often never re-evaluates, so the `false` edge is lost. Prod 0.65.0: 7 of 9 hidden
workspaces' selected terminals read `lifecycle_state = active`; v0.66.1 Release
staging never throttled after `select-workspace`.

## Fix (model-driven, view path kept)

1. `Workspace.applyPanelVisibility(workspaceVisible:)` (Sources/Workspace.swift):
   walk panes → tabs, resolve panel, compute visibility with the same rule as the
   view (`WorkspaceContentView.panelVisibleInUI(isWorkspaceVisible:isSelectedInPane:isFocused:)`),
   call `applyVisibility` on `TerminalPanel` / `BrowserPanel`. Hibernated stays
   pinned; transitions are idempotent so double-firing with the view is safe.
2. `TabManager.selectedTabId.didSet`: synchronously (not in the async block)
   call it with `false` on the previous workspace and `true` on the new one,
   resolved by id from `tabs`.
3. Pane-tab selection (`Workspace.applyTabSelection`, the funnel for
   didSelectTab / createTab / focus-surface): after the selection settles, call
   `applyPanelVisibility(workspaceVisible: owningTabManager.selectedTabId == id)`,
   so a tab selected inside a hidden workspace stays throttled (a freshly created
   panel starts `.active` and its hidden view may never appear).

No new state, no timers, nothing on typing-latency paths.

## Tests (c11Tests, CI only; no local xcodebuild)

- Two workspaces with terminals: select second → first's terminal `.throttled`,
  second's `.active`; select first → inverse.
- New terminal tab created in a hidden workspace → every terminal in it
  `.throttled`.

## Validation

CI `build` + c11-unit green. Orchestrator validates on a nap-free staging build
(procedure on C11-225): `get-metadata` after `select-workspace` away reads
`throttled` for every terminal in the old workspace; renderer thread idle.
