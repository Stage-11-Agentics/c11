# C11-41: Reorganize macOS menu bar — reduce miscellany, group by intent

The c11 main menu bar has grown organically (notifications top-level menu, workspace submenu inside File, splits + browser nav + workspace switching + sidebar toggle all mixed inside View) and now reads as random and miscellaneous. Audit the current state of every item in c11 / File / Edit / View / Notifications / Window / Help, then redesign for legibility — group by user intent, surface c11-native concepts (panes, surfaces, workspaces, sidebar) at appropriate levels, and decide whether 'Notifications' should remain top-level or fold into View.

## Plan (locked, 2026-05-15)

Plan was fully authored in `notes/task_01KRN2NCZRBFA07B7Q7G3M8P2J.md` Part 2. Target top-level shape:

```
🍎  c11  File  Edit  View  Workspace  Pane  Browser  Notifications  Window
```

Execution buckets:

- **A. Menu structure rewrite** in `Sources/c11App.swift` (lines 402–1010): replace File `.newItem` group with 3 items (New Window ⌘⇧N / Open Folder… ⌘O / Close Other Tabs in Pane ⌘⌥T); strip after-newItem; flatten Find under Edit; replace `.toolbar` with Toggle Sidebar / Appearance ▶ / Titlebar Controls ▶ / Always Show Shortcut Hints / Full Screen; add `CommandMenu("Workspace")` absorbing `workspaceCommandMenuContent` + workspace switching; add `CommandMenu("Pane")` with splits, focus, surface ops, Rename Tab; add `CommandMenu("Browser")`; `CommandGroup(replacing: .help) { }`.
- **B. Promote Appearance from Debug → View**: Appearance Mode picker (Light/Dark/System/Auto), Titlebar Controls Style picker, Always Show Shortcut Hints toggle.
- **C. Tab Bar feature deletion**: delete `TabBarChromeState`, `tabBarChromeStateRaw` AppStorage, `cycleTabBarChromeState()`, `Action.toggleTabBarChrome`; hardcode Full at every read site; remove Settings UI surface.
- **D. Rename Tab keybind**: `KeyboardShortcutSettings.swift:154–155` → ⌘⇧E (frees ⌘R for Browser Reload Page).
- **E. Tests + localizations**: update `c11Tests/NotificationAndMenuBarTests.swift`, fix any UI-test menu-path navigation, ensure localization call-sites compile.

Workflow: implement each bucket, build (`xcodebuild -scheme c11 -configuration Debug build`), iterate failures, commit per bucket, push `feat/c11-41-menu-reorg`, open PR, set Lattice to `review` with PR URL.

Out of scope: Notifications unread badge, Help menu re-add, Theme M1b graduation, status bar reorg.
