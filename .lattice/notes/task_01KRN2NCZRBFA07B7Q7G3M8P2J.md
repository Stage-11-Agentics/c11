# C11-41 — c11 macOS menu bar: state of every item

**Ticket:** Reorganize macOS menu bar — reduce miscellany, group by intent
**Status:** in_planning
**Source of truth:** `Sources/c11App.swift` (`.commands { ... }` block, lines 402–1010) + `Sources/AppDelegate.swift` (Services injection, status bar menu). Defaults pulled from `Sources/KeyboardShortcutSettings.swift`.

This note captures **every item** in the c11 main menu bar in production builds (DEBUG-only items called out separately). It is a snapshot of behavior, not a redesign proposal — that conversation comes after.

---

## Conventions used below

- **⌘** = Command, **⇧** = Shift, **⌥** = Option, **⌃** = Control.
- Shortcuts marked *(default — rebindable)* are `StoredShortcut`s read from `UserDefaults`; the user can change them in Settings → Keyboard Shortcuts.
- Shortcuts written without that suffix are hardcoded in `.keyboardShortcut(...)` calls.
- **`[DEBUG]`** = present only in DEBUG builds.
- "Disabled when" notes the predicate that greys an item out.

---

## 1. Apple menu (system)

System-provided. c11 inserts one item via `AppDelegate.installStage11ServiceInfoMenuItem()` (AppDelegate.swift:11550–11570): **"Stage 11 Service Info"** appears after Services in the app menu, not the Apple menu. Otherwise untouched.

---

## 2. c11 menu (top-level app menu)

Implemented via `CommandGroup(replacing: .appInfo)` (c11App.swift:405) plus `CommandGroup(replacing: .appSettings) { }` (line 403, which removes the default "Settings…" item so the custom one in .appInfo wins).

| # | Item | Shortcut | What it does |
|---|------|----------|--------------|
| 1 | About c11 | — | Opens `AboutWindowController.shared`. |
| 2 | c11 Settings… | ⌘, | `appDelegate.openPreferencesWindow(debugSource: "menu.cmdComma")`. |
| 3 | Check for Updates… | — | `appDelegate.checkForUpdates(nil)`. |
| 4 | *(Install Update)* — `InstallUpdateMenuItem` | — | Conditional: visible when an update is downloaded and ready to install. View-modeled by `appDelegate.updateViewModel`. |
| 5 | Reload Configuration | ⌘⇧, | `GhosttyApp.shared.reloadConfiguration(source: "menu.reload_configuration")` — reloads Ghostty config (theme, font, key bindings driven from Ghostty side). |
| 6 | **`[DEBUG]`** *(injected by AppDelegate)* Stage 11 Service Info | — | Diagnostic dump for the Stage 11 macOS service registration. Lives in the app menu, just after the standard Services submenu. |

System-provided items macOS still draws in this menu (untouched by c11):
- Services ▶ (system submenu)
- Hide c11 (⌘H)
- Hide Others (⌘⌥H)
- Show All
- Quit c11 (⌘Q)

---

## 3. File menu

Two `CommandGroup`s mutate this menu:
- `CommandGroup(replacing: .newItem)` (c11App.swift:743) — replaces the standard "New / Open / Save" cluster wholesale.
- `CommandGroup(after: .newItem)` (line 779) — appends a large block below it.

| # | Item | Shortcut | What it does |
|---|------|----------|--------------|
| 1 | New Window | ⌘⇧N *(default — rebindable)* | `appDelegate.openNewMainWindow(nil)`. |
| 2 | New Workspace | ⌘N *(default — rebindable)* | Presents the Create Workspace sheet if AppDelegate is available; otherwise falls back to `activeTabManager.addTab()`. |
| 3 | Open Folder… | ⌘O *(default — rebindable)* | Shows an `NSOpenPanel` (directories only), then adds a workspace rooted at that path in the preferred main window. |
| — | — separator — | | |
| 4 | Go to Workspace… | ⌘P | Posts `commandPaletteSwitcherRequested` notification — opens the workspace switcher palette. |
| 5 | Command Palette… | ⌘⇧P | Posts `commandPaletteRequested` notification — opens the full command palette. |
| — | — separator — | | |
| 6 | Close Tab | ⌘W | `closePanelOrWindow()` — closes focused tab/surface with confirmation. If it's the last surface in the workspace, also closes workspace and (if last) window. |
| 7 | Close Other Tabs in Pane | ⌘⌥T | Closes every other tab in the focused pane. **Disabled when** `!activeTabManager.canCloseOtherTabsInFocusedPane()`. |
| 8 | Close Workspace | ⌘⇧W *(default — rebindable)* | `closeTabOrWindow()` — closes the current workspace with confirmation; closes the window if it was the last workspace. |
| 9 | **Workspace ▶** (submenu) | — | See §3a below. |
| 10 | Reopen Closed Browser Pane | ⌘⇧T | `activeTabManager.reopenMostRecentlyClosedBrowserPanel()`. |

System items macOS keeps in File above our replacement:
- (none — `.newItem` is replaced, so no standard New/Open/Save/Print items appear)
- "Close Window" (⌃⌘W in defaults) is **not** in the menu — exists only as a `StoredShortcut.closeWindow` for routing.

### 3a. File → Workspace submenu

Built by `workspaceCommandMenuContent(manager:)` (c11App.swift:1310–1427). All items operate on `manager.selectedWorkspace`.

| # | Item | Shortcut | What it does | Disabled when |
|---|------|----------|--------------|---------------|
| 1 | Pin Workspace / Unpin Workspace | — | Toggles `workspace.isPinned`. Label flips based on current state. | No selected workspace |
| 2 | Rename Workspace… | — | `AppDelegate.shared?.requestRenameWorkspaceViaCommandPalette()`. | No selected workspace |
| 3 | Remove Custom Workspace Name | — | Clears the custom title for the selected workspace. | Only present when `workspace.hasCustomTitle` |
| — | — separator — | | | |
| 4 | Move Up | — | `moveSelectedWorkspace(by: -1)`. | No selected workspace OR already at top |
| 5 | Move Down | — | `moveSelectedWorkspace(by: 1)`. | No selected workspace OR already at bottom |
| 6 | Move to Top | — | `manager.moveTabsToTop([workspace.id])`. | No selected workspace OR already at index 0 |
| 7 | **Move Workspace to Window ▶** | — | Submenu: "New Window" + each other open main window as a target. | No selected workspace; per-target disabled if it's the current window |
| — | — separator — | | | |
| 8 | Close Workspace | — | `manager.closeCurrentWorkspaceWithConfirmation()`. (Same action as File #8 above.) | No selected workspace |
| 9 | Close Other Workspaces | — | Closes all peers, excluding pinned. | No selected workspace OR only one tab |
| 10 | Close Workspaces Below | — | Closes peers after this one in the sidebar order, excluding pinned. | No selected workspace OR it's the last |
| 11 | Close Workspaces Above | — | Closes peers before this one in the sidebar order, excluding pinned. | No selected workspace OR it's the first |
| — | — separator — | | | |
| 12 | Hibernate Workspace / Resume Workspace | — | Snapshots browser surfaces and stops their WebContent processes (terminals stay on auto-throttle). Flips between "Hibernate" and "Resume" based on `workspace.isHibernated`. Tooltip explains terminal behavior. | No selected workspace |
| — | — separator — | | | |
| 13 | Mark Workspace as Read | — | `notificationStore.markRead(forTabId:)`. | Workspace has no unread notifications |
| 14 | Mark Workspace as Unread | — | `notificationStore.markUnread(forTabId:)`. | Workspace has no read notifications |

---

## 4. Edit menu

`CommandGroup(after: .textEditing)` (c11App.swift:827) appends a single **Find ▶** submenu. The standard system items (Undo, Redo, Cut, Copy, Paste, Delete, Select All, Start Dictation, Emoji & Symbols) are untouched and remain macOS-default.

### 4a. Edit → Find submenu

| # | Item | Shortcut | What it does |
|---|------|----------|--------------|
| 1 | Find… | ⌘F | `activeTabManager.startSearch()` — opens the in-surface find bar. |
| 2 | Find Next | ⌘G | `activeTabManager.findNext()`. |
| 3 | Find Previous | ⌘⇧G | `activeTabManager.findPrevious()`. |
| — | — separator — | | |
| 4 | Hide Find Bar | ⌘⇧F | `activeTabManager.hideFind()`. **Disabled when** `!activeTabManager.isFindVisible`. |
| — | — separator — | | |
| 5 | Use Selection for Find | ⌘E | `activeTabManager.searchSelection()`. **Disabled when** `!activeTabManager.canUseSelectionForFind`. |

---

## 5. View menu

`CommandGroup(after: .toolbar)` (c11App.swift:866). This is by far the largest, most heterogenous menu — sidebar chrome, tab-bar chrome, surface focus, browser navigation, browser zoom, workspace switching, splits, and notifications all live here.

The system "Enter/Exit Full Screen" item provided by `.toolbar` is preserved above our additions.

| # | Item | Shortcut | What it does |
|---|------|----------|--------------|
| 1 | Toggle Sidebar | ⌘B *(default — rebindable)* | Calls `AppDelegate.shared?.toggleSidebarInActiveMainWindow()`; falls back to `sidebarState.toggle()`. |
| 2 | **Tab Bar ▶** | — | Submenu with three radio-ish picks: **Full**, **Shrunk**, **Hidden** — each sets `tabBarChromeStateRaw` to the matching `TabBarChromeState` enum. No keyboard shortcuts on the children. |
| 3 | Cycle Tab Bar | ⌘⇧B *(default — rebindable)* | `cycleTabBarChromeState()` — full → shrunk → hidden → full. |
| — | — separator — | | |
| 4 | Next Surface | ⌘⇧] *(default — rebindable)* | `activeTabManager.selectNextSurface()`. |
| 5 | Previous Surface | ⌘⇧[ *(default — rebindable)* | `activeTabManager.selectPreviousSurface()`. |
| 6 | Back | ⌘[ | `activeTabManager.focusedBrowserPanel?.goBack()` — only meaningful when a browser surface is focused. |
| 7 | Forward | ⌘] | `activeTabManager.focusedBrowserPanel?.goForward()`. |
| 8 | Reload Page | ⌘R | `activeTabManager.focusedBrowserPanel?.reload()`. |
| 9 | Toggle Developer Tools | ⌘⌥I *(default — rebindable)* | Toggles Web Inspector on the focused browser surface; beeps if no browser focused. |
| 10 | Show JavaScript Console | ⌘⌥C *(default — rebindable)* | Opens JS console on the focused browser surface; beeps if no browser focused. |
| 11 | Zoom In | ⌘= | `activeTabManager.zoomInFocusedBrowser()`. |
| 12 | Zoom Out | ⌘- | `activeTabManager.zoomOutFocusedBrowser()`. |
| 13 | Actual Size | ⌘0 | `activeTabManager.resetZoomFocusedBrowser()`. |
| 14 | Clear Browser History | — | `BrowserHistoryStore.shared.clearHistory()`. |
| 15 | Import Browser Data… | — | Presents `BrowserDataImportCoordinator.shared.presentImportDialog()` (deferred via `DispatchQueue.main.async` so it fires after menu tracking ends). |
| 16 | Next Workspace | ⌃] *(default — rebindable)* | `activeTabManager.selectNextTab()`. |
| 17 | Previous Workspace | ⌃[ *(default — rebindable)* | `activeTabManager.selectPreviousTab()`. |
| 18 | Rename Workspace… | ⌘⇧R *(default — rebindable)* | `AppDelegate.shared?.requestRenameWorkspaceViaCommandPalette()`. |
| — | — separator — | | |
| 19 | Split Right | ⌘D *(default — rebindable)* | `performSplitFromMenu(direction: .right)` — splits current pane (any surface type); new pane is a terminal. |
| 20 | Split Down | ⌘⇧D *(default — rebindable)* | `performSplitFromMenu(direction: .down)`. |
| 21 | Split Browser Right | ⌘⌥D *(default — rebindable)* | `performBrowserSplitFromMenu(direction: .right)` — new pane is a browser. |
| 22 | Split Browser Down | ⌘⇧⌥D *(default — rebindable)* | `performBrowserSplitFromMenu(direction: .down)`. |
| — | — separator — | | |
| 23 | Workspace 1 | ⌘1 | Selects sidebar workspace 1 (mapped via `WorkspaceShortcutMapper.workspaceIndex`). |
| 24 | Workspace 2 | ⌘2 | …workspace 2. |
| 25 | Workspace 3 | ⌘3 | … |
| 26 | Workspace 4 | ⌘4 | … |
| 27 | Workspace 5 | ⌘5 | … |
| 28 | Workspace 6 | ⌘6 | … |
| 29 | Workspace 7 | ⌘7 | … |
| 30 | Workspace 8 | ⌘8 | … |
| 31 | Workspace 9 | ⌘9 | Special-cased: maps to the **last** workspace, not just the ninth, when there are more than 9. |
| — | — separator — | | |
| 32 | Jump to Latest Unread | ⌃Return *(default — rebindable)* | `AppDelegate.shared?.jumpToLatestUnread()`. |
| 33 | Show Notifications | ⌘I *(default — rebindable)* | `showNotificationsPopover()`. |

---

## 6. Notifications menu (top-level)

`CommandMenu("Notifications")` (c11App.swift:443). Sits between View and Window in the menu bar. Body is rebuilt every menu open from `notificationMenuSnapshot` (a `NotificationMenuSnapshotBuilder` over `notificationStore.notifications`).

| # | Item | Shortcut | What it does |
|---|------|----------|--------------|
| 1 | `snapshot.stateHintTitle` (e.g., "3 unread notifications" / "No unread notifications") | — | Always disabled — informational header. |
| — | — separator (only if there are recent notifications) — | | |
| 2..N | Recent notification rows (variable count, formatted by `MenuBarNotificationLineFormatter.menuTitle`) | — | Each row opens its source surface via `appDelegate.openNotification(tabId:surfaceId:notificationId:)`. |
| — | — separator (only if there are recent notifications) — | | |
| N+1 | Show Notifications | ⌘I *(default — rebindable)* | Opens the notifications popover. (Same action as View #33.) |
| N+2 | Jump to Latest Unread | ⌃Return *(default — rebindable)* | `appDelegate.jumpToLatestUnread()`. (Same action as View #32.) **Disabled when** `!snapshot.hasUnreadNotifications`. |
| N+3 | Mark All Read | — | `notificationStore.markAllRead()`. **Disabled when** `!snapshot.hasUnreadNotifications`. |
| N+4 | Clear All | — | `notificationStore.clearAll()`. **Disabled when** `!snapshot.hasNotifications`. |

---

## 7. Window menu

System-default. c11 adds no `CommandGroup` for Window. macOS provides:
- Minimize (⌘M)
- Zoom
- Bring All to Front
- Dynamic list of all open c11 windows (with checkmark on the key window)

Note: "Move Workspace to Window" lives in File → Workspace, not here.

---

## 8. Help menu

System-default. c11 adds no `CommandGroup` for Help. macOS provides:
- c11 Help (no help book is registered → menu item exists but is non-functional)
- Search field (system-provided)

---

## 9. `[DEBUG]` Update Pill menu

`CommandMenu("Update Pill")` (c11App.swift:424). Five items, all for poking the in-app update notification pill:

| Item | Action |
|------|--------|
| Show Update Pill | `appDelegate.showUpdatePill(nil)` |
| Show Long Nightly Pill | `appDelegate.showUpdatePillLongNightly(nil)` |
| Show Loading State | `appDelegate.showUpdatePillLoading(nil)` |
| Hide Update Pill | `appDelegate.hideUpdatePill(nil)` |
| Automatic Update Pill | `appDelegate.clearUpdatePillOverride(nil)` |

---

## 10. `[DEBUG]` Debug menu

`CommandMenu("Debug")` (c11App.swift:482). The largest debug surface; flat at the top, then submenus.

**Top-level items:**
- New Tab With Lorem Search Text
- New Tab With Large Scrollback
- Open Workspaces for All Workspace Colors
- Open Stress Workspaces and Load All Terminals

— separator —

- Debug: Dump Active Theme (opens a markdown surface with the resolved theme JSON)
- Debug: Toggle Theme Engine (with checkmark when disabled)
- Debug: Show Theme Folder (reveals bundled `stage11.toml` in Finder)
- Debug: Show Resolution Trace ▶ — one item per `ThemeRole` (logs trace to NSLog + diagnostics)
- Debug: Theme M1b ▶ — seven feature-flag toggles for the M1b theme migration (SurfaceTitleBarView, BrowserPanelView, MarkdownPanelView, Workspace.bonsplitAppearance, ContentView.TabItemView, ContentView.customTitlebar, WorkspaceContentView context). All store to `@AppStorage`.

— separator —

- **Debug Windows ▶** — submenu, grouped:
  - Debug Window Controls…
  - Browser Import Hint Debug…
  - Browser Profile Popover Debug…
  - Settings/About Titlebar Debug…
  - — separator —
  - Sidebar Debug…
  - Background Debug…
  - Menu Bar Extra Debug…
  - — separator —
  - Open All Debug Windows

- Browser Toolbar Button Spacing ▶ — picker (radio items per supported spacing value)
- Always Show Shortcut Hints (toggle, bound to `$alwaysShowShortcutHints`)
- Show Dev Build Banner (toggle, bound to `$showSidebarDevBuildBanner`)

— separator —

- Titlebar Controls Style (picker, radio items per `TitlebarControlsStyle` case, bound to `$titlebarControlsStyle`)

— separator —

- Copy Update Logs (`appDelegate.copyUpdateLogs(nil)`)
- Copy Focus Logs (`appDelegate.copyFocusLogs(nil)`)

— separator —

- Trigger Sentry Test Crash (`appDelegate.triggerSentryTestCrash(nil)`)

---

## Cross-cutting notes

These observations come from reading the menu surface, not from a redesign:

1. **The same action lives in two menus.** "Show Notifications" (⌘I) and "Jump to Latest Unread" (⌃↩) appear in both Notifications and View. "Rename Workspace…" appears in both View (⌘⇧R) and File → Workspace.
2. **View is a junk drawer.** Thirty-three items spanning sidebar chrome, tab-bar chrome, surface focus, browser navigation, browser zoom, browser data, workspace switching, workspace rename, splits, workspace-number quick-pick, and notifications. Multiple unrelated categories share separators inconsistently.
3. **File → Workspace is a context menu in disguise.** Fourteen items operating on `manager.selectedWorkspace`. It's a near-1:1 duplicate of the sidebar workspace right-click menu, mounted under File so it gets keyboard discoverability.
4. **Splits are buried.** Split Right/Down (⌘D / ⌘⇧D) are arguably the most c11-native operation alongside surface focus, but they sit deep in View between "Rename Workspace" and "Workspace 1..9".
5. **Browser-only commands are not grouped or labeled.** Back/Forward/Reload/Zoom/Dev Tools/Clear History/Import live in View flat, with no visual cue that they only act on a focused browser surface. Several beep silently when invoked over a terminal.
6. **Window is empty of c11 affordances.** "Move Workspace to Window" lives under File → Workspace; "New Window" is in File; the Window menu offers only macOS-default actions.
7. **Help is dead.** No help book; the item exists only because macOS draws it.
8. **Notifications-as-a-top-level-menu is a relatively new (2026-02-12) addition** that duplicates View items rather than replacing them.
9. **Open Folder… is the only "Open" verb in File**, and it implies the file/folder vocabulary of a document app — c11 is a terminal multiplexer, not a doc editor, so File's mental model is workspace-centric not document-centric.

---

## Files referenced

- `Sources/c11App.swift:402–1010` — full `.commands { ... }` block
- `Sources/c11App.swift:1310–1427` — `workspaceCommandMenuContent(manager:)`
- `Sources/AppDelegate.swift:11506+` — `validateMenuItem(_:)` and Stage 11 Service Info injection
- `Sources/KeyboardShortcutSettings.swift:128–200` — default `StoredShortcut` values
- `Sources/AppDelegate.swift:12193+` — status bar menu (separate surface, not part of this audit)

---

# Part 2 — Proposed reorganization

Synthesized from operator dialogue 2026-05-15. Direction = **hybrid** (macOS chrome + c11-native verbs). Decisions locked:

| Layer | Choice | Notes |
|---|---|---|
| Top-level shape | macOS chrome + c11 verbs | 9 menus, Help dropped |
| Browser actions | Top-level Browser menu | Even though disabled when no browser focused, it earns visibility |
| Notifications | Top-level, dedup from View | Recent (2026-02-12) addition is correct; the dup in View was the bug |
| New verbs | Each primitive owns its New | File becomes minimal; Workspace owns "New Workspace"; Pane owns Split + New Surface |
| View | Chrome + Appearance | Theme/Appearance/Titlebar Controls promoted out of Debug into View |
| Help | **Removed entirely** | `CommandGroup(replacing: .help) { }`; macOS hides empty Help menus |
| Find | Flat under Edit | Matches Safari/Mail/Notes — no submenu |

## Proposed top-level menu bar

```
🍎  c11  File  Edit  View  Workspace  Pane  Browser  Notifications  Window
```

9 menus, each with a clear theme. View has a real meaning ("how c11 looks"). Workspace and Pane carry the c11-native primitives. Browser holds the browser surface's verbs. Help is gone.

---

## c11 menu

Largely unchanged from current — already a coherent app menu.

```
About c11
Settings…                          ⌘,
Check for Updates…
[Install Update]                   (conditional, when update downloaded)
Reload Configuration               ⌘⇧,
—
Services ▶                         (system)
Stage 11 Service Info              (DEBUG-only, AppDelegate-injected)
—
Hide c11                           ⌘H   (system)
Hide Others                        ⌘⌥H  (system)
Show All                                (system)
—
Quit c11                           ⌘Q   (system)
```

---

## File menu

Shrinks to **window + close**. Mac muscle memory: ⌘W closes the focused thing, ⌘⇧W closes the workspace, ⌘⇧N for a new window. Everything else moves to its primitive's menu.

```
New Window                         ⌘⇧N
Open Folder…                       ⌘O
—
Close Other Tabs in Pane           ⌘⌥T
```

3 items. The most minimal File menu of any non-trivial Mac app.

**Decisions (2026-05-15):**
- **"Open Folder…" stays in File**, not Workspace. The Mac "Open" muscle memory is strong enough that moving it would be net-negative even though the action creates a workspace.
- **All three single-target Close verbs removed** (Close Tab, Close Workspace, Close Window). Each has a GUI affordance (pane tab-bar X, sidebar workspace hover-X, red traffic light) AND a keyboard shortcut bound at the responder-chain level. The menu entries were redundant; their shortcuts (⌘W, ⌘⇧W, ⌃⌘W) all still work without the menu items.
- **"Close Other Tabs in Pane" stays** — no equivalent GUI affordance, so the menu is the discovery surface for ⌘⌥T.

---

## Edit menu

System Undo/Redo/Cut/Copy/Paste/Select All untouched. Find lands flat per Mac convention.

```
(system items)
—
Find…                              ⌘F
Find Next                          ⌘G
Find Previous                      ⌘⇧G
Use Selection for Find             ⌘E
Hide Find Bar                      ⌘⇧F
```

---

## View menu

The biggest reduction. Was 33 items spanning eight categories; now 5–7 items spanning two (Chrome, Appearance).

```
Toggle Sidebar                     ⌘B
—
Appearance ▶
   Light
   Dark
   System
   Auto
Titlebar Controls ▶
   (existing TitlebarControlsStyle cases)
—
Always Show Shortcut Hints         (toggle)
—
Enter Full Screen                  ⌃⌘F  (system)
```

**Decisions (2026-05-15):**
- Tab Bar submenu (Full/Shrunk/Hidden) and Cycle Tab Bar removed from View.
- **The feature is removed entirely.** Delete `TabBarChromeState` enum, `tabBarChromeStateRaw` AppStorage, `cycleTabBarChromeState()`, the `toggleTabBarChrome` shortcut action + binding UI, and any Settings panel surface. Pick one canonical tab-bar style (likely Full — most informative) and hardcode it at every call site.
- Migration note: any user whose current preference is Shrunk or Hidden has their layout silently reset to the canonical style. Accept as part of the cleanup.

**Moved out of View:**
- Next/Previous Surface → Pane
- Back / Forward / Reload Page → Browser
- Zoom In/Out/Actual Size → Browser
- Toggle Developer Tools / Show JS Console → Browser
- Clear Browser History / Import Browser Data → Browser
- Next/Previous Workspace, Rename Workspace, Workspace 1–9 → Workspace
- Split Right/Down, Split Browser Right/Down → Pane
- Jump to Latest Unread, Show Notifications → Notifications (already there, this is the dedup)

**Moved into View from Debug:**
- Appearance Mode (Light/Dark/System/Auto)
- Titlebar Controls Style
- Always Show Shortcut Hints toggle

---

## Workspace menu (new top-level)

Absorbs the entire File → Workspace submenu and the workspace-related View items. The single home for everything workspace-shaped.

```
New Workspace                      ⌘N
—
Rename Workspace…                  ⌘⇧R
Pin Workspace        / Unpin Workspace
Remove Custom Workspace Name       (when workspace.hasCustomTitle)
—
Next Workspace                     ⌃]
Previous Workspace                 ⌃[
Go to Workspace…                   ⌘P
Workspace 1–9                      ⌘1–⌘9
—
Move Up
Move Down
Move to Top
Move Workspace to Window ▶
—
Hibernate Workspace  / Resume Workspace
—
Mark Workspace as Read
Mark Workspace as Unread
—
Close Workspace                    ⌘⇧W
Close Other Workspaces
Close Workspaces Below
Close Workspaces Above
```

Notes:
- "Open Folder…" stays in File (operator decision 2026-05-15) — the Mac "Open" muscle memory wins. The action still creates a workspace; the menu home is the only thing that differs.
- "Close Workspace" still appears in File for Mac convention (⌘⇧W is the universal "close this workspace" muscle memory); it's just *also* listed here for completeness within the Workspace menu's close family.
- The four close variants ladder naturally at the bottom.

---

## Pane menu (new top-level)

Splits + focus navigation + surface-within-pane operations. The single home for spatial pane manipulation.

```
Split Right                        ⌘D
Split Down                         ⌘⇧D
Split Browser Right                ⌘⌥D
Split Browser Down                 ⌘⇧⌥D
—
Focus Left                         ⌘⌥←
Focus Right                        ⌘⌥→
Focus Up                           ⌘⌥↑
Focus Down                         ⌘⌥↓
Toggle Pane Zoom                   ⌘⇧↩
—
New Surface ▶
   New Terminal                    ⌘T
   New Browser                     ⌘⇧L
   New Markdown
Next Surface                       ⌘⇧]
Previous Surface                   ⌘⇧[
Rename Tab                         ⌘R
```

Open question — **⌘R conflict**: Reload Page (Browser) and Rename Tab (Pane) both default to ⌘R today. Currently they coexist via focus-dependent dispatch but it's fragile. Suggest treating this as a follow-up — rebind one in a separate ticket. The reorg shouldn't be blocked on it.

---

## Browser menu (new top-level)

All browser-surface verbs in one home. Greys out when no browser surface focused.

```
Back                               ⌘[
Forward                            ⌘]
Reload Page                        ⌘R
—
Zoom In                            ⌘=
Zoom Out                           ⌘-
Actual Size                        ⌘0
—
Reopen Closed Browser Pane         ⌘⇧T
—
Toggle Developer Tools             ⌘⌥I
Show JavaScript Console            ⌘⌥C
—
Import Browser Data…
Clear Browser History
```

"Reopen Closed Browser Pane" moved here from File — it's specifically a browser-pane history action and parallels browser reopen-tab conventions.

---

## Notifications menu (top-level, dedup)

Same structure as today, but Show Notifications and Jump to Latest Unread no longer duplicated in View.

```
{state hint}                       (disabled, e.g., "3 unread")
—
Recent notification rows (when any)
—
Show Notifications                 ⌘I
Jump to Latest Unread              ⌃↩
Mark All Read
Clear All
```

Future polish (not blocking this ticket): badge the menu title itself with unread count, so the menu bar reads `Notifications •3` when there's unread. Brings the always-visible status function up to the top-level.

---

## Window menu

macOS-default, untouched. We intentionally do **not** mirror "Move Workspace to Window" here — it lives in Workspace, where the action originates.

```
Minimize                           ⌘M   (system)
Zoom                                    (system)
—
Bring All to Front                      (system)
(dynamic list of open c11 windows)
```

---

## Help menu

**Removed.** `CommandGroup(replacing: .help) { }` empties it; macOS hides empty Help menus.

If a Help menu is wanted later (docs link, Send Feedback, Report an Issue, Release Notes), it's a separate small ticket. Don't preserve it dead for tradition.

---

## DEBUG menus (unchanged structurally, shrunken)

- **Update Pill** — keep all five items.
- **Debug** — keep structurally, but remove:
  - "Always Show Shortcut Hints" (moved to View)
  - "Titlebar Controls Style" (moved to View)
  - Theme Engine toggle + Theme M1b submenu *may* graduate to View → Appearance later; for now leave in Debug since they're feature-flag-shaped, not user-facing.

---

## Open questions resolved (2026-05-15)

1. **Canonical tab-bar style** = **Full** (most informative; matches what most users see today).
2. **⌘R rebind for Rename Tab** = **⌘⇧E** (free, easy reach, mnemonic "rEname"). Update `KeyboardShortcutSettings.Action.renameTab.defaultShortcut`.
3. **Notifications unread badge** — **out of scope.** Operator does not want the feature. Not in this ticket, not in a follow-up.

---

## Scope of work — single ticket plan

All of the above folds into C11-41. Work breakdown:

### A. Menu structure rewrite — the main scope

`Sources/c11App.swift` lines 402–1010 get rebuilt:
- `CommandGroup(replacing: .newItem)` → new minimal File body (New Window, Open Folder…, Close Other Tabs in Pane — three items only).
- `CommandGroup(after: .newItem)` → currently holds Go to Workspace / Command Palette / Close family / File→Workspace submenu / Reopen Closed Browser Pane — most of this *evacuates* to other menus. Just Command Palette + Go to Workspace remain here (or move to c11 menu? — see decision below).
- `CommandGroup(replacing: .help) { }` → kills Help menu.
- `CommandGroup(replacing: .toolbar)` → new View body (Toggle Sidebar, Appearance ▶, Titlebar Controls ▶, Always Show Shortcut Hints, system Full Screen). Removes everything else currently there.
- New `CommandMenu("Workspace")` — absorbs `workspaceCommandMenuContent(manager:)` (currently at c11App.swift:1310) plus the workspace-switching items that moved out of View (Next/Previous Workspace, Go to Workspace, Workspace 1–9, Rename Workspace).
- New `CommandMenu("Pane")` — Split Right/Down, Split Browser Right/Down, Focus Left/Right/Up/Down, Toggle Pane Zoom, New Surface ▶ (Terminal/Browser/Markdown), Next/Previous Surface, Rename Tab.
- New `CommandMenu("Browser")` — Back, Forward, Reload Page, Zoom In/Out/Actual Size, Reopen Closed Browser Pane, Toggle Dev Tools, Show JS Console, Import Browser Data, Clear Browser History.
- `CommandMenu("Notifications")` — kept, internally unchanged; the *dedup* happens by removing those items from View, not by editing Notifications itself.

### B. Move Appearance controls from Debug → View

Currently in the DEBUG-only Debug menu (c11App.swift:482+) the following live as production-style controls hiding behind the `#if DEBUG` gate:
- "Titlebar Controls Style" picker (line ~719) — bound to `$titlebarControlsStyle`
- "Always Show Shortcut Hints" toggle (line ~711)
- *(New)* Appearance Mode picker — needs to be authored if not yet present in production; backing is `AppearanceSettings.mode(for:)` + `appearanceMode` AppStorage. Wire to View, not gated by DEBUG.

These move into the production-visible View menu. Debug menu shrinks.

### C. Tab Bar feature removal

- Pick canonical state (recommend Full; confirm with operator).
- Delete `TabBarChromeState` enum + the `tabBarChromeStateRaw` AppStorage key.
- Delete `cycleTabBarChromeState()` (c11App.swift:1067).
- Delete `toggleTabBarChromeShortcut` plumbing and `KeyboardShortcutSettings.Action.toggleTabBarChrome`.
- Audit every site that reads `tabBarChromeStateRaw` to hardcode the canonical state inline.
- Remove the Settings UI for it (wherever it lives — `SettingsView` likely surfaces this somewhere).
- Migration: existing users on non-canonical states are silently moved to canonical (their old AppStorage key just stops being read).

### D. ⌘R conflict resolution

- Pick a free chord for Rename Tab (currently `KeyboardShortcutSettings.Action.renameTab.defaultShortcut` returns ⌘R). Suggest ⌘⇧E or ⌘⌥R.
- Update default in `KeyboardShortcutSettings.swift:154–155`.
- Migration note: existing users whose custom binding is ⌘R will still see ⌘R; only fresh installs or resets pick up the new default.

### E. Tests + localization + Settings UI

- `c11Tests/NotificationAndMenuBarTests.swift` — update for the new menu structure, especially the dedup.
- Any UI test that navigates menus by path needs new paths (most likely lives in `c11UITests/`).
- Every `String(localized: "menu.{old}.{key}", ...)` for relocated items: keep the key but update the surrounding menu when re-authoring. Localizations are auto-tracked from source.
- Settings → Keyboard Shortcuts UI: the action set is unchanged, but a few default-shortcut values change (Rename Tab) — regression-test that the Reset button uses the new defaults.

### F. Stage 11 Service Info menu item (no work)

The DEBUG-injected `AppDelegate.installStage11ServiceInfoMenuItem()` keeps targeting the app menu — no change needed.

---

## What's *not* in scope (deferred or explicitly cut)

- **Notifications unread badge in menu title** (`Notifications •3`). Operator decision 2026-05-15: not wanted. Not a follow-up; cut entirely.
- Help menu re-add with real items (docs / feedback / issue link). Greenfield, future ticket if ever.
- Theme M1b debug toggle graduation to View → Appearance. Stays in Debug for now; graduation when the M1b migration completes.
- Per-workspace notification preferences / Do Not Disturb mode. Out of scope.
- Status bar (menu bar extra) reorg. Separate surface, not part of this audit.

---

## Scope summary

Five buckets, one PR: **A** Menu structure rewrite · **B** Appearance promoted from Debug → View · **C** Tab Bar feature deletion (hardcode Full) · **D** Rename Tab default → ⌘⇧E (frees ⌘R for Browser Reload) · **E** Tests + localizations.

