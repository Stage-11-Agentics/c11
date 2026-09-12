# C11-206: simulate_shortcut can wedge DEBUG builds on an app-modal confirm

FOUND BY. C11-204's audit of every runModal() call under Sources/, done while fixing the browser insecure-HTTP wedge.

MECHANISM. SocketHandlers/SocketDispatch.swift:732 -> TerminalController.simulateShortcut (TerminalController.swift:4327) wraps its work in v2MainSync, a literal DispatchQueue.main.sync, and synthesizes an NSEvent into AppDelegate.handleCustomShortcut. Two shortcuts land on app-modal NSAlerts:
  - cmd+q -> AppDelegate.handleQuitShortcutWarning (AppDelegate.swift:10699)
  - cmd+shift+w -> AppDelegate.confirmCloseMainWindow (AppDelegate.swift:5968)
Both call alert.runModal(), which spins a nested run loop on main. Because the socket dispatch is main.sync, the socket worker thread blocks inside that nested loop too: the app AND the CLI wedge until a human clicks. The v2 verb debug.shortcut.simulate (SocketHandlers/DebugHandlers.swift:24,387) has the same reach.

SCOPE. simulate_shortcut is DEBUG-only, so this cannot hit a shipped build. It can hit any agent working in this repo, because the dev loop runs DEBUG builds.

SECOND INSTANCE, same family. AppDelegate.swift:2758-2761 auto-fires BrowserDataImportCoordinator.shared.presentImportDialog() 0.4s after launch when CMUX_UI_TEST_BROWSER_IMPORT_AUTO_OPEN=1. That reaches NSApp.runModal(for:) at Panels/BrowserPanel.swift:9447 (a real nested modal session) with nothing human in the loop, so a UI-test harness that sets the env var and then talks to the socket deadlocks.

FIX DIRECTIONS.
  - The two confirms are legitimately human prompts, so the cleanest fix is to sheet them (beginSheetModal) when a window exists rather than to gate the socket verb. confirmCloseMainWindow returns Bool synchronously, so it needs a continuation-shaped rewrite.
  - Cheaper containment: make simulateShortcut dispatch async on main so at least the socket thread is not held, and refuse to synthesize shortcuts that are known to raise a modal.
  - For the auto-open path, present the wizard non-modally under the UI-test env var.

RELATED. C11-204 (PR #417) fixed the same shape in the browser: insecure-HTTP prompt, JS dialogs (panel and popup), and the import outcome alert. It also added a Pitfalls entry in CLAUDE.md and browserPresentModalAlert as the sanctioned helper for browser modals.
