# Workspace Sidebar Card Map

C11-5 makes the workspace name the first visual anchor in every sidebar card.

| Input | Source | Sidebar location |
| --- | --- | --- |
| Workspace name | `Workspace.title`; custom names still come from `Workspace.customTitle` | First row, left aligned, before all metadata; wraps to two lines before tail truncation |
| Close button / shortcut hint | Hover state, keyboard shortcut settings | First row, trailing fixed slot |
| Pinned state | `Workspace.isPinned` | First row, trailing indicator before the close/shortcut slot |
| Unread notification badge | `TerminalNotificationStore.unreadCount(forTabId:)` | First row, trailing badge before the close/shortcut slot |
| Active / multi-select state | `TabManager.selectedTabId`, sidebar multi-selection | Card background, border, foreground palette, drag opacity |
| Workspace custom color | `Workspace.customColor`, theme sidebar roles | Card fill/rail/outline styling |
| Agent identity chip | Focused surface metadata `terminal_type`, `model`, `model_label` via `AgentChipResolver` | Second row, subdued; never precedes the workspace name |
| Latest notification message | `TerminalNotificationStore.latestNotification(forTabId:)` | Below agent chip, when the sidebar notification-message setting is enabled |
| Remote / SSH target and status | `Workspace.remoteDisplayTarget`, `remoteConnectionState`, remote error status entries | Below notification, when SSH details are enabled |
| Custom sidebar metadata rows | `Workspace.statusEntries` from `set_status` / `report_meta` | Auxiliary detail area below remote status |
| Markdown metadata blocks | `Workspace.metadataBlocks` from `report_meta_block` | Auxiliary detail area below status rows |
| Latest log row | `Workspace.logEntries.last` from `log` | Auxiliary detail area below metadata blocks |
| Progress bar and label | `Workspace.progress` from `set_progress` | Auxiliary detail area below latest log |
| Branch and directory rows | Workspace and per-surface branch/directory state | Auxiliary detail area below progress; vertical or inline per setting |
| PR / MR rows | `Workspace.pullRequest`, `panelPullRequests` from `report_pr` / `report_review` | Auxiliary detail area below branch/directory rows |
| Ports row | `Workspace.listeningPorts` | Bottom of auxiliary detail area |

The global hide-details setting still hides auxiliary rows. The workspace name, first-row controls, and agent chip layout remain independent of that setting so identity stays scannable.
