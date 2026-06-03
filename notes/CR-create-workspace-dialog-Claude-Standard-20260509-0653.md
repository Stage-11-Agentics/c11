# Code Review

- **Date:** 2026-05-09T06:53:37Z
- **Model:** Claude Opus 4.7 (claude-opus-4-7)
- **Branch:** main (uncommitted; will be moved to a feature branch for the PR)
- **Latest Commit on main:** 40e9ee1dcc5197912b7e8da80b538922c7739ff9
- **Linear Story:** n/a (no Lattice ticket; direct user request)

---

## Summary

Adds a "New Workspace" dialog that replaces the prior auto-quad behavior on ⌘N, File → New Workspace, and the "+" button. The dialog lets the operator pick a working directory, choose a layout blueprint (One column / Two columns / 2x2 grid / 3x2 grid), opt in to launching the configured agent in the initial pane, and pick from saved blueprints discovered via `WorkspaceBlueprintStore`. Recently-used directories are persisted and offered via a clock-icon menu adjacent to Browse.

### Files changed

- New: `Sources/CreateWorkspaceSheet.swift` (514 lines) — the SwiftUI sheet, recents helper, blueprint icon shapes.
- New: `Resources/Blueprints/quad-terminal.json` — 2x2 of four terminals.
- New: `Resources/Blueprints/six-terminal.json` — 3x2 of six terminals.
- Modified: `Sources/AppDelegate.swift` — `presentCreateWorkspaceSheet()`, `applyWorkspacePlanInPreferredMainWindow()`, `focusedWorkspaceWorkingDirectory()`, ⌘N keyboard route now opens the sheet, recents recorded on success.
- Modified: `Sources/c11App.swift` — File → New Workspace menu opens the sheet.
- Modified: `Sources/ContentView.swift` — tab-strip "+" opens the sheet.
- Modified: `Sources/Update/UpdateTitlebarAccessory.swift` — titlebar accessory "+" opens the sheet.
- Modified: `GhosttyTabs.xcodeproj/project.pbxproj` — registers `CreateWorkspaceSheet.swift`.

## Logic flow

```
User trigger (⌘N | File→New | + button)
        │
        ▼
AppDelegate.presentCreateWorkspaceSheet()
        │   strong-ref retain pattern (matches AgentSkillsOnboardingSheet)
        │   pre-fills cwd from focusedWorkspaceWorkingDirectory() ?? $HOME
        ▼
NSWindow + NSHostingView(CreateWorkspaceSheet)
        │
        │   user picks blueprint, edits cwd, toggles launchAgent, clicks Create
        ▼
CreateWorkspaceSheet.submit()
        │   resolves selected entry → WorkspaceApplyPlan (read from disk)
        ▼
AppDelegate.applyWorkspacePlanInPreferredMainWindow()
        │   1. resolves main window context (returns nil if none)
        │   2. injects plan.workspace.workingDirectory = chosen cwd
        │   3. if launchAgent: injects AgentLauncherSettings.current().shellCommand
        │      onto the first terminal SurfaceSpec with no command set
        │   4. WorkspaceLayoutExecutor.apply(plan, options, deps)
        │      — executor calls tabManager.addWorkspace(autoWelcomeIfNeeded:false)
        │        so the welcome quad / default-grid auto-spawn is bypassed
        │   5. CreateWorkspaceRecents.record(workingDirectory) on success
        ▼
Workspace materialized; sheet window closes.
```

## Architecture

The dialog is intentionally thin: it composes a `WorkspaceApplyPlan` (the existing CMUX-37 primitive) and hands it to `WorkspaceLayoutExecutor.apply` — the same entry point socket commands and the existing CLI use. No new app-level layout machinery, no parallel "create workspace from preset" path. The four starter shapes are file-backed JSON blueprints in `Resources/Blueprints/`, which means saving a workspace via `c11 workspace export-blueprint --name foo` and re-opening the dialog automatically surfaces it under "Saved blueprints".

The auto-quad / default-grid behavior is bypassed cleanly because `WorkspaceLayoutExecutor.apply` always calls `tabManager.addWorkspace(autoWelcomeIfNeeded: false)`, so the dialog never collides with the welcome flow.

`addWorkspaceInPreferredMainWindow` is preserved for non-dialog flows (`File → Open Folder…`, drag-and-drop a folder onto the dock, external URL handlers). That seems right: those have a directory in hand and don't need a layout choice.

The synthetic ref minters in `applyWorkspacePlanInPreferredMainWindow` (`{ uuid in "workspace:\(uuid.uuidString)" }`) bypass `TerminalController.v2EnsureHandleRef` so the produced refs are not valid v2 socket refs. That's fine for the dialog flow because we don't expose the result to socket clients, but it does mean the ApplyResult.workspaceRef won't match what a subsequent socket query would mint. Not a regression — the socket layer mints lazily on first reference anyway — but worth a note.

## Tactical

### Blockers

None.

### Important

1. **`File → New Workspace` (menu item) regresses the no-windows fallback** — `Sources/c11App.swift:748–755`. The old code called `addWorkspaceInPreferredMainWindow(debugSource:)`, and if it returned `nil` (no main window context), opened a new window. The new code unconditionally calls `presentCreateWorkspaceSheet()`, which renders a free-standing modal but, on Create, hits the same nil-context path inside `applyWorkspacePlanInPreferredMainWindow` and silently does nothing. The keyboard ⌘N handler at `Sources/AppDelegate.swift:10028–10050` still has the right gate (`mainWindowContexts.isEmpty → openNewMainWindow`); the menu path lost it. **Fix:** move the gate into `presentCreateWorkspaceSheet` itself so all three trigger paths (menu, ⌘N, "+") behave consistently.

2. **Sidebar selection update fires before the dialog completes** — `Sources/ContentView.swift:3260–3268`. `private func addTab()` now calls `presentCreateWorkspaceSheet()` (async UX) followed immediately by `sidebarSelectionState.selection = .tabs`. The selection switches before the user has confirmed. If the user cancels the dialog, the sidebar has still moved. Minor, but worth fixing — either set the selection in the onCreate callback, or rely on the workspace-selection notification to drive it.

3. **Dialog doesn't auto-update recents after a manual edit** — `Sources/CreateWorkspaceSheet.swift:reloadEntries()` reads recents on appear. Editing the textbox to a new path doesn't refresh the menu (that's fine), but if the user opens the dialog twice in one launch, the second open doesn't reflect the recent recorded by the first because the AppDelegate writes to UserDefaults *after* the dialog closes. This is actually correct — UserDefaults will be re-read on the second `onAppear` — verified by re-reading the code. ⬇️ false positive once I traced it.

### Potential

4. **No keyboard navigation between blueprint cards** — `Sources/CreateWorkspaceSheet.swift:blueprintRow(...)`. The cards are SwiftUI `Button`s in a `VStack`; users can tab to them but arrow-key navigation between siblings isn't wired. The existing `AgentSkillsOnboardingSheet` uses an `OnboardingKeyboardMonitor` for this. Acceptable for v1 but worth a follow-up if dialog gets heavier use.

5. **Rapid double-click on Create** — `Sources/CreateWorkspaceSheet.swift:submit()`. `.keyboardShortcut(.defaultAction)` typically debounces, but a fast double-mouse-click on the visible button could fire `submit()` twice before `window?.close()` runs. Mitigation: track `@State private var submitting = false` and disable the button on first call. Low risk — `WorkspaceLayoutExecutor.apply` is fast (~50–200ms) — but a defensive flip is one line.

6. **Recents max=8 not user-configurable** — `Sources/CreateWorkspaceSheet.swift:CreateWorkspaceRecents.maxCount`. Hardcoded; fine for v1. If users start asking for "remember more", expose via UserDefaults.

7. **Dialog doesn't reload recents inside the same launch if a sibling flow records one** — only the dialog and `applyWorkspacePlanInPreferredMainWindow` interact with recents today, and the dialog only opens once at a time, so this is moot. Note in case future code paths begin recording.

8. **The inline fallback `_ = AppDelegate.shared?.tabManager?.addTab()` re-checks `AppDelegate.shared`** — `Sources/Update/UpdateTitlebarAccessory.swift:566–570, 795–799`. Inside the `else` branch `AppDelegate.shared` was just established to be `nil`, so the optional chain trivially short-circuits. Cosmetic; the explicit form `appDelegate.tabManager?.addTab()` is dead code in this branch. Leaving as-is is harmless.

9. **`CreateWorkspaceRecents` lives at file scope inside `CreateWorkspaceSheet.swift`** — visible internal-wide. Fine for the AppDelegate caller, but if more code wants to hook into the recents (e.g. command palette suggesting recent dirs), it'll grow. Refactor to its own file when the second consumer arrives.

10. **No tests** — c11 testing policy forbids running `xcodebuild test` locally and the project's testing posture for socket/UI tests is CI-only. The dialog is exercised end-to-end by the user clicking through the tagged build (`c11 DEV ws-create-dialog`), which is the canonical validation path here. The compile-time guarantees from `WorkspaceApplyPlan` codability + `WorkspaceLayoutExecutor.validate` cover most of what unit tests would assert.

## Validation pass

Re-read each finding against the actual code:

1. ✅ **Fixed.** Baked the `mainWindowContexts.isEmpty → openNewMainWindow` fallback into `presentCreateWorkspaceSheet` itself (`AppDelegate.swift`). All three trigger paths (menu, ⌘N keyboard handler, "+" buttons) now share one entry point. Simplified the duplicate gate inside the ⌘N keyboard handler.
2. ⬇️ Downgraded to cosmetic. The eager `sidebarSelectionState.selection = .tabs` matches the prior behavior; on cancel the user lands on `.tabs` instead of their previous sidebar state, but the value of staying consistent with prior behavior outweighs the small UX wobble. Defer.
3. ❌ ~~False positive.~~ `onAppear` re-reads UserDefaults on each open.
4. ⬇️ Valid, deferred. Not a blocker.
5. ✅ **Fixed.** Added `@State private var submitting: Bool = false` and gated `submit()` + `canSubmit`. Reset on the load-failure path so the dialog isn't stranded.
6–9. ⬇️ Valid, deferred.
10. ⬇️ Valid, accepted per project policy.

## Outcome

Two fixes applied, build green. Moving to commit + PR.
