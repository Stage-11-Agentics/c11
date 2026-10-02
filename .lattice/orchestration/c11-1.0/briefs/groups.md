# Seat: Groups Model Astra

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** Groups Model Astra
- **Actor:** `agent:astra-groups`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-groups` (branch `c11-1.0/C11-259-workspace-groups`, base origin/main `0ff8887e5e`)
- **Seat id for envelopes:** `groups`

## Queue
1. **C11-259** (P1, L): workspace groups folder model, persistence, CLI, atomic batch reorder.
2. **C11-260** (P1, L): sidebar folders, drag/drop, visible attention. Plan it right after C11-259 so the two plans agree; it implements after C11-259 merges, on a new branch `c11-1.0/C11-260-groups-sidebar` from origin/main at that time.

## Specifics
- Atin: workspace groups are **core; test carefully**. 50+ workspaces, drag and drop, restore round-trips, no typing-latency regression. C11-261 (validation script, another seat) will test your work; make your plan name what it must exercise.
- Keep the folder model (`WorkspaceGroup {id, name, color, icon, isCollapsed, isPinned}`, `Workspace.groupId`). Avoid cmux's anchor-workspace model and its follow-up bugs (upstream #5253, #8925, #9176, #13688, #15892); read upstream #4815/#5018 via `git show upstream/main:...` or `gh` read-only. No auto-filing by root (cut).
- The sidebar body and `TabItemView` are typing-latency hot paths: plan exactly how equatable/precomputed parameters stay intact, and how 50 workspaces are measured against the C11-270 soak baseline.
- A flag inside a collapsed group must stay visible (violet badge); waiting count excludes suppressed tabs.
- C11-248 (vocabulary rename: pane→area, surface→tab) is landing; use the new names and check origin/main for its seams.
