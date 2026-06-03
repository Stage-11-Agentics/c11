# C11-119: Sidebar Waiting Agent + Workspace Nav Cluster

## Approach
Replace `SidebarJumpToUnreadButton` with a two-row cluster:
1. **Row 1 (WaitingAgentRow):** Renamed "Waiting Agent" button with paper-fill lit state and gold hairline
2. **Row 2 (WorkspaceNavRow):** ▲/▼ arrows for prev/next workspace, disabled at boundaries, press-and-hold auto-repeat

## Files to change
- `Sources/BrandColors.swift` — add `paperFill` color (#E8E2D0)
- `Sources/ContentView.swift` — replace `SidebarJumpToUnreadButton` with `SidebarWaitingAgentCluster`

## Key decisions
- No wraparound on arrows (disable at first/last workspace)
- Use dynamic shortcut display string (not hardcoded)
- Gold hairline on lit state via overlay stroke
- Press-and-hold via Timer-based repeat gesture
