# C11-117: Sidebar X on a background tab: focus that tab before showing the close-confirm overlay

Repro: open at least two workspaces in a sidebar; while viewing workspace A, click the X on background tab B (any state that triggers the close-confirm overlay — running process, etc.).

Observed: the confirm overlay appears (per the comment in TabManager.closeWorkspaceIfRunningProcess, anchored on the currently-selected workspace because the off-screen workspace's anchor view is hidden and reports no frame). The operator's view never switches to B, so the dialog references a workspace the operator isn't looking at.

Expected: clicking the X on a background tab should first select that tab (bring it into view), then present the close-confirm overlay on that tab. The overlay mounts on the workspace being closed.

Scope: single-workspace close path triggered by the sidebar X button. The multi-close path (multiple sidebar selection or Cmd+Shift+W with multi-select) is intentionally anchored on the currently-selected workspace and out of scope.

Touch points:
- Sources/TabManager.swift closeWorkspaceIfRunningProcess (requiresConfirmation branch; current 'host = selectedWorkspace ?? workspace' line)
- c11Tests/TabManagerUnitTests.swift — add a c11LogicTests-safe unit test asserting selection switches to the workspace being closed before the confirmation handler fires.
