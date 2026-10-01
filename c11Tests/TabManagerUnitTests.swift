import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

let lastSurfaceCloseShortcutDefaultsKey = "closeWorkspaceOnLastSurfaceShortcut"

func drainMainQueue() {
    let expectation = XCTestExpectation(description: "drain main queue")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTWaiter().wait(for: [expectation], timeout: 5.0)
}

@MainActor
final class TabManagerChildExitCloseTests: XCTestCase {
    func testChildExitOnLastPanelClosesSelectedWorkspaceAndKeepsIndexStable() {
        let manager = WorkspaceManager()
        let first = manager.workspaces[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedWorkspaceId, second.id)

        guard let secondPanelId = second.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        manager.closePanelAfterChildExited(workspaceId: second.id, surfaceId: secondPanelId)

        XCTAssertEqual(manager.workspaces.map(\.id), [first.id, third.id])
        XCTAssertEqual(
            manager.selectedWorkspaceId,
            third.id,
            "Expected selection to stay at the same index after deleting the selected workspace"
        )
    }

    func testChildExitOnLastPanelInLastWorkspaceSelectsPreviousWorkspace() {
        let manager = WorkspaceManager()
        let first = manager.workspaces[0]
        let second = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedWorkspaceId, second.id)

        guard let secondPanelId = second.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        manager.closePanelAfterChildExited(workspaceId: second.id, surfaceId: secondPanelId)

        XCTAssertEqual(manager.workspaces.map(\.id), [first.id])
        XCTAssertEqual(
            manager.selectedWorkspaceId,
            first.id,
            "Expected previous workspace to be selected after closing the last-index workspace"
        )
    }

    func testChildExitOnNonLastPanelClosesOnlyPanel() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        guard let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panel to be created")
            return
        }

        let panelCountBefore = workspace.panels.count
        manager.closePanelAfterChildExited(workspaceId: workspace.id, surfaceId: splitPanel.id)

        XCTAssertEqual(manager.workspaces.count, 1)
        XCTAssertEqual(manager.workspaces.first?.id, workspace.id)
        XCTAssertEqual(workspace.panels.count, panelCountBefore - 1)
        XCTAssertNotNil(workspace.panels[initialPanelId], "Expected sibling panel to remain")
    }
}


@MainActor
final class TabManagerWorkspaceOwnershipTests: XCTestCase {
    func testCloseWorkspaceIgnoresWorkspaceNotOwnedByManager() {
        let manager = WorkspaceManager()
        _ = manager.addWorkspace()
        let initialWorkspaceIds = manager.workspaces.map(\.id)
        let initialSelectedWorkspaceId = manager.selectedWorkspaceId

        let externalWorkspace = Workspace(title: "External workspace")
        let externalPanelCountBefore = externalWorkspace.panels.count
        let externalTabTitlesBefore = externalWorkspace.tabTitles

        manager.closeWorkspace(externalWorkspace)

        XCTAssertEqual(manager.workspaces.map(\.id), initialWorkspaceIds)
        XCTAssertEqual(manager.selectedWorkspaceId, initialSelectedWorkspaceId)
        XCTAssertEqual(externalWorkspace.panels.count, externalPanelCountBefore)
        XCTAssertEqual(externalWorkspace.tabTitles, externalTabTitlesBefore)
    }
}


@MainActor
final class TabManagerCloseWorkspacesWithConfirmationTests: XCTestCase {
    func testCloseWorkspacesWithConfirmationPromptsOnceAndClosesAcceptedWorkspaces() {
        let manager = WorkspaceManager()
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setCustomTitle(workspaceId: manager.workspaces[0].id, title: "Alpha")
        manager.setCustomTitle(workspaceId: second.id, title: "Beta")
        manager.setCustomTitle(workspaceId: third.id, title: "Gamma")

        var prompts: [(title: String, message: String)] = []
        manager.workspaceCloseConfirmationHandler = { title, message in
            prompts.append((title, message))
            return true
        }

        manager.closeWorkspacesWithConfirmation([manager.workspaces[0].id, second.id], allowPinned: true)

        let expectedMessage = String(
            format: String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            ),
            locale: .current,
            Int64(2),
            "• Alpha\n• Beta"
        )
        XCTAssertEqual(prompts.count, 1, "Expected a single confirmation prompt for multi-close")
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        )
        XCTAssertEqual(prompts.first?.message, expectedMessage)
        XCTAssertEqual(manager.workspaces.map(\.title), ["Gamma"])
    }

    func testCloseWorkspacesWithConfirmationKeepsWorkspacesWhenCancelled() {
        let manager = WorkspaceManager()
        let second = manager.addWorkspace()
        manager.setCustomTitle(workspaceId: manager.workspaces[0].id, title: "Alpha")
        manager.setCustomTitle(workspaceId: second.id, title: "Beta")

        var prompts: [(title: String, message: String)] = []
        manager.workspaceCloseConfirmationHandler = { title, message in
            prompts.append((title, message))
            return false
        }

        manager.closeWorkspacesWithConfirmation([manager.workspaces[0].id, second.id], allowPinned: true)

        let expectedMessage = String(
            format: String(
                localized: "dialog.closeWorkspacesWindow.message",
                defaultValue: "This will close the current window, its %1$lld workspaces, and all of their panels:\n%2$@"
            ),
            locale: .current,
            Int64(2),
            "• Alpha\n• Beta"
        )
        XCTAssertEqual(prompts.count, 1)
        // Title differentiates "close window" (last workspaces) from
        // "close workspaces" (some workspaces). Replaces the previous
        // acceptCmdD assertion since acceptCmdD was an NSAlert-only signal.
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
        )
        XCTAssertEqual(prompts.first?.message, expectedMessage)
        XCTAssertEqual(manager.workspaces.map(\.title), ["Alpha", "Beta"])
    }

    func testCloseWorkspaceWithConfirmationOnBackgroundTabFocusesItBeforePrompting() {
        // C11-117: clicking the X on a background sidebar tab must select that
        // workspace before the close-confirm overlay is shown, so the dialog
        // mounts on the workspace being closed rather than the previously-visible
        // one.
        let envKey = "CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"
        setenv(envKey, "1", 1)
        defer { unsetenv(envKey) }

        let manager = WorkspaceManager()
        let foreground = manager.workspaces[0]
        let background = manager.addWorkspace()
        manager.selectWorkspace(foreground)
        XCTAssertEqual(manager.selectedWorkspaceId, foreground.id)

        var selectedWorkspaceIdWhenPrompted: UUID?
        manager.workspaceCloseConfirmationHandler = { [weak manager] _, _ in
            selectedWorkspaceIdWhenPrompted = manager?.selectedWorkspaceId
            return false
        }

        manager.closeWorkspaceWithConfirmation(background)

        XCTAssertEqual(
            selectedWorkspaceIdWhenPrompted,
            background.id,
            "Expected the background tab to be selected before the confirmation prompt fires"
        )
        XCTAssertEqual(manager.selectedWorkspaceId, background.id)
        XCTAssertEqual(
            manager.workspaces.map(\.id),
            [foreground.id, background.id],
            "Both workspaces remain because the operator cancelled"
        )
    }

    func testCloseWorkspaceWithConfirmationOnForegroundTabKeepsSelection() {
        // The foreground-tab case is the no-op: selection already matches, the
        // confirm prompt fires once, and selection stays unchanged.
        let envKey = "CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"
        setenv(envKey, "1", 1)
        defer { unsetenv(envKey) }

        let manager = WorkspaceManager()
        let foreground = manager.workspaces[0]
        _ = manager.addWorkspace()
        XCTAssertEqual(manager.selectedWorkspaceId, foreground.id)

        var promptCount = 0
        manager.workspaceCloseConfirmationHandler = { _, _ in
            promptCount += 1
            return false
        }

        manager.closeWorkspaceWithConfirmation(foreground)

        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(manager.selectedWorkspaceId, foreground.id)
    }

    func testClosingLoneIdleTerminalWorkspaceDoesNotPrompt() {
        let manager = WorkspaceManager()
        let second = manager.addWorkspace()

        var promptCount = 0
        manager.workspaceCloseConfirmationHandler = { _, _ in
            promptCount += 1
            return false
        }

        manager.closeWorkspaceWithConfirmation(second)

        XCTAssertEqual(promptCount, 0)
        XCTAssertFalse(manager.workspaces.contains(where: { $0.id == second.id }))
    }

    func testClosingPinnedWorkspacePromptsEvenWhenIdle() {
        let manager = WorkspaceManager()
        let second = manager.addWorkspace()
        manager.setPinned(second, pinned: true)

        var promptCount = 0
        manager.workspaceCloseConfirmationHandler = { _, _ in
            promptCount += 1
            return false
        }

        manager.closeWorkspaceWithConfirmation(second)

        XCTAssertEqual(promptCount, 1)
        XCTAssertTrue(manager.workspaces.contains(where: { $0.id == second.id }), "Cancelling keeps the workspace")
    }

    func testClosingWorkspaceWithSeveralSurfacesPromptsEvenWhenIdle() throws {
        let manager = WorkspaceManager()
        let second = manager.addWorkspace()
        let firstPanelId = try XCTUnwrap(second.focusedPanelId)
        XCTAssertNotNil(second.newTerminalSplit(from: firstPanelId, orientation: .horizontal))

        var promptCount = 0
        manager.workspaceCloseConfirmationHandler = { _, _ in
            promptCount += 1
            return false
        }

        manager.closeWorkspaceWithConfirmation(second)

        XCTAssertEqual(promptCount, 1)
        XCTAssertTrue(manager.workspaces.contains(where: { $0.id == second.id }), "Cancelling keeps the workspace")
    }

    func testCloseCurrentWorkspaceWithConfirmationUsesSidebarMultiSelection() {
        let manager = WorkspaceManager()
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setCustomTitle(workspaceId: manager.workspaces[0].id, title: "Alpha")
        manager.setCustomTitle(workspaceId: second.id, title: "Beta")
        manager.setCustomTitle(workspaceId: third.id, title: "Gamma")
        manager.selectWorkspace(second)
        manager.setSidebarSelectedWorkspaceIds([manager.workspaces[0].id, second.id])

        var prompts: [(title: String, message: String)] = []
        manager.workspaceCloseConfirmationHandler = { title, message in
            prompts.append((title, message))
            return false
        }

        manager.closeCurrentWorkspaceWithConfirmation()

        let expectedMessage = String(
            format: String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            ),
            locale: .current,
            Int64(2),
            "• Alpha\n• Beta"
        )
        XCTAssertEqual(prompts.count, 1, "Expected Cmd+Shift+W path to reuse the multi-close summary dialog")
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        )
        XCTAssertEqual(prompts.first?.message, expectedMessage)
        XCTAssertEqual(manager.workspaces.map(\.title), ["Alpha", "Beta", "Gamma"])
    }
}


@MainActor
final class TabManagerCloseCurrentPanelTests: XCTestCase {
    func testRuntimeCloseSkipsConfirmationWhenShellReportsPromptIdle() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected selected workspace and focused terminal panel")
            return
        }

        terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)
        workspace.updateTabShellActivityState(panelId: panelId, state: .promptIdle)

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return false
        }

        manager.closeRuntimeSurfaceWithConfirmation(workspaceId: workspace.id, surfaceId: panelId)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(promptCount, 0, "Runtime closes should honor prompt-idle shell state")
        XCTAssertNil(workspace.panels[panelId], "Expected the original panel to close")
        XCTAssertEqual(workspace.panels.count, 1, "Expected a replacement surface after closing the last panel")
    }

    func testRuntimeClosePromptsWhenShellReportsRunningCommand() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected selected workspace and focused terminal panel")
            return
        }

        terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(false)
        workspace.updateTabShellActivityState(panelId: panelId, state: .commandRunning)

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return false
        }

        manager.closeRuntimeSurfaceWithConfirmation(workspaceId: workspace.id, surfaceId: panelId)

        XCTAssertEqual(promptCount, 1, "Running commands should still require confirmation")
        XCTAssertNotNil(workspace.panels[panelId], "Prompt rejection should keep the original panel open")
    }

    func testCloseCurrentPanelClosesWorkspaceWhenItOwnsTheLastSurface() {
        let manager = WorkspaceManager()
        let firstWorkspace = manager.workspaces[0]
        let secondWorkspace = manager.addWorkspace()
        manager.selectWorkspace(secondWorkspace)

        guard let secondPanelId = secondWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        XCTAssertEqual(manager.selectedWorkspaceId, secondWorkspace.id)
        XCTAssertEqual(secondWorkspace.panels.count, 1)

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.workspaces.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedWorkspaceId, firstWorkspace.id)
        XCTAssertNil(secondWorkspace.panels[secondPanelId])
        XCTAssertTrue(secondWorkspace.panels.isEmpty)
    }

    func testCloseCurrentPanelKeepsWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: lastSurfaceCloseShortcutDefaultsKey)
        defaults.set(false, forKey: lastSurfaceCloseShortcutDefaultsKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: lastSurfaceCloseShortcutDefaultsKey)
            } else {
                defaults.removeObject(forKey: lastSurfaceCloseShortcutDefaultsKey)
            }
        }

        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace and focused panel")
            return
        }

        let initialWorkspaceId = workspace.id

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.workspaces.count, 1)
        XCTAssertEqual(manager.selectedWorkspaceId, initialWorkspaceId)
        XCTAssertEqual(manager.workspaces.first?.id, initialWorkspaceId)
        XCTAssertNil(workspace.panels[initialPanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(workspace.focusedPanelId, initialPanelId)
    }

    func testClosePanelButtonClosesWorkspaceWhenItOwnsTheLastSurface() {
        let manager = WorkspaceManager()
        let firstWorkspace = manager.workspaces[0]
        let secondWorkspace = manager.addWorkspace()
        manager.selectWorkspace(secondWorkspace)

        guard let secondPanelId = secondWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        XCTAssertEqual(manager.selectedWorkspaceId, secondWorkspace.id)
        XCTAssertEqual(secondWorkspace.panels.count, 1)

        guard let secondSurfaceId = secondWorkspace.bonsplitTabIdFromTabId(secondPanelId) else {
            XCTFail("Expected bonsplit surface ID for focused panel")
            return
        }

        secondWorkspace.markExplicitClose(bonsplitTabId: secondSurfaceId)
        XCTAssertFalse(secondWorkspace.closeTab(secondPanelId))
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.workspaces.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedWorkspaceId, firstWorkspace.id)
        XCTAssertNil(secondWorkspace.panels[secondPanelId])
        XCTAssertTrue(secondWorkspace.panels.isEmpty)
    }

    func testClosePanelButtonStillClosesWorkspaceWhenKeepWorkspaceOpenPreferenceIsEnabled() {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: lastSurfaceCloseShortcutDefaultsKey)
        defaults.set(false, forKey: lastSurfaceCloseShortcutDefaultsKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: lastSurfaceCloseShortcutDefaultsKey)
            } else {
                defaults.removeObject(forKey: lastSurfaceCloseShortcutDefaultsKey)
            }
        }

        let manager = WorkspaceManager()
        let firstWorkspace = manager.workspaces[0]
        let secondWorkspace = manager.addWorkspace()
        manager.selectWorkspace(secondWorkspace)

        guard let secondPanelId = secondWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        guard let secondSurfaceId = secondWorkspace.bonsplitTabIdFromTabId(secondPanelId) else {
            XCTFail("Expected bonsplit surface ID for focused panel")
            return
        }

        secondWorkspace.markExplicitClose(bonsplitTabId: secondSurfaceId)
        XCTAssertFalse(secondWorkspace.closeTab(secondPanelId))
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.workspaces.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedWorkspaceId, firstWorkspace.id)
        XCTAssertNil(secondWorkspace.panels[secondPanelId])
        XCTAssertTrue(secondWorkspace.panels.isEmpty)
    }

    func testGenericClosePanelKeepsWorkspaceOpenWithoutExplicitCloseMarker() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace and focused panel")
            return
        }

        let initialWorkspaceId = workspace.id
        XCTAssertEqual(manager.workspaces.count, 1)
        XCTAssertEqual(workspace.panels.count, 1)

        XCTAssertTrue(workspace.closeTab(initialPanelId))
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.workspaces.count, 1)
        XCTAssertEqual(manager.selectedWorkspaceId, initialWorkspaceId)
        XCTAssertEqual(manager.workspaces.first?.id, initialWorkspaceId)
        XCTAssertNil(workspace.panels[initialPanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(workspace.focusedPanelId, initialPanelId)
    }

    func testCloseCurrentPanelIgnoresStaleSurfaceId() {
        let manager = WorkspaceManager()
        let firstWorkspace = manager.workspaces[0]
        let secondWorkspace = manager.addWorkspace()

        manager.closePanelWithConfirmation(workspaceId: secondWorkspace.id, surfaceId: UUID())

        XCTAssertEqual(manager.workspaces.map(\.id), [firstWorkspace.id, secondWorkspace.id])
    }

    func testCloseCurrentPanelClearsNotificationsForClosedSurface() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = WorkspaceManager()
        let store = TerminalNotificationStore.shared

        let originalWorkspaceManager = appDelegate.workspaceManager
        let originalNotificationStore = appDelegate.notificationStore
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.workspaceManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.workspaceManager = originalWorkspaceManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace and focused panel")
            return
        }

        store.addNotification(
            workspaceId: workspace.id,
            surfaceId: initialPanelId,
            title: "Unread",
            subtitle: "",
            body: ""
        )
        XCTAssertTrue(store.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: initialPanelId))

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertFalse(store.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: initialPanelId))
    }
}


@MainActor
final class TabManagerNotificationFocusTests: XCTestCase {
    func testFocusTabFromNotificationClearsSplitZoomBeforeFocusingTargetPanel() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        workspace.focusPanel(leftPanelId)
        XCTAssertTrue(workspace.toggleSplitZoom(panelId: leftPanelId), "Expected split zoom to enable")
        XCTAssertTrue(workspace.bonsplitController.isSplitZoomed, "Expected workspace to start zoomed")

        XCTAssertTrue(manager.focusTabFromNotification(workspace.id, surfaceId: rightPanel.id))
        drainMainQueue()
        drainMainQueue()

        XCTAssertFalse(
            workspace.bonsplitController.isSplitZoomed,
            "Expected notification focus to exit split zoom so the target pane becomes visible"
        )
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id, "Expected notification target panel to be focused")
    }

    func testFocusTabFromNotificationReturnsFalseForMissingPanel() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        XCTAssertFalse(manager.focusTabFromNotification(workspace.id, surfaceId: UUID()))
    }
}


@MainActor
final class TabManagerPendingUnfocusPolicyTests: XCTestCase {
    func testDoesNotUnfocusWhenPendingTabIsCurrentlySelected() {
        let workspaceId = UUID()

        XCTAssertFalse(
            WorkspaceManager.shouldUnfocusPendingWorkspace(
                pendingWorkspaceId: workspaceId,
                selectedWorkspaceId: workspaceId
            )
        )
    }

    func testUnfocusesWhenPendingTabIsNotSelected() {
        XCTAssertTrue(
            WorkspaceManager.shouldUnfocusPendingWorkspace(
                pendingWorkspaceId: UUID(),
                selectedWorkspaceId: UUID()
            )
        )
        XCTAssertTrue(
            WorkspaceManager.shouldUnfocusPendingWorkspace(
                pendingWorkspaceId: UUID(),
                selectedWorkspaceId: nil
            )
        )
    }
}


@MainActor
final class TabManagerSurfaceCreationTests: XCTestCase {
    func testNewSurfaceFocusesCreatedSurface() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected a selected workspace")
            return
        }

        let beforePanels = Set(workspace.panels.keys)
        manager.newSurface()
        let afterPanels = Set(workspace.panels.keys)

        let createdPanels = afterPanels.subtracting(beforePanels)
        XCTAssertEqual(createdPanels.count, 1, "Expected one new surface for Cmd+T path")
        guard let createdPanelId = createdPanels.first else { return }

        XCTAssertEqual(
            workspace.focusedPanelId,
            createdPanelId,
            "Expected newly created surface to be focused"
        )
    }

    func testOpenBrowserInsertAtEndPlacesNewBrowserAtPaneEnd() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected focused workspace and pane")
            return
        }

        // Add one extra surface so we verify append-to-end rather than first insert behavior.
        _ = workspace.newTerminalSurface(inPane: paneId, focus: false)

        guard let browserPanelId = manager.openBrowser(insertAtEnd: true) else {
            XCTFail("Expected browser panel to be created")
            return
        }

        let bonsplitTabs = workspace.bonsplitController.tabs(inPane: paneId)
        guard let lastSurfaceId = bonsplitTabs.last?.id else {
            XCTFail("Expected at least one surface in pane")
            return
        }

        XCTAssertEqual(
            workspace.tabIdFromBonsplitTabId(lastSurfaceId),
            browserPanelId,
            "Expected Cmd+Shift+B/Cmd+L open path to append browser surface at end"
        )
        XCTAssertEqual(workspace.focusedPanelId, browserPanelId, "Expected opened browser surface to be focused")
    }

    func testOpenBrowserInWorkspaceSplitRightSelectsTargetWorkspaceAndCreatesSplit() {
        let manager = WorkspaceManager()
        guard let initialWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected initial selected workspace")
            return
        }
        guard let url = URL(string: "https://example.com/pull/123") else {
            XCTFail("Expected test URL to be valid")
            return
        }

        let targetWorkspace = manager.addWorkspace(select: false)
        manager.selectWorkspace(initialWorkspace)
        let initialPaneCount = targetWorkspace.bonsplitController.allPaneIds.count
        let initialPanelCount = targetWorkspace.panels.count

        guard let browserPanelId = manager.openBrowser(
            inWorkspace: targetWorkspace.id,
            url: url,
            preferSplitRight: true,
            insertAtEnd: true
        ) else {
            XCTFail("Expected browser panel to be created in target workspace")
            return
        }

        XCTAssertEqual(manager.selectedWorkspaceId, targetWorkspace.id, "Expected target workspace to become selected")
        XCTAssertEqual(
            targetWorkspace.bonsplitController.allPaneIds.count,
            initialPaneCount + 1,
            "Expected split-right browser open to create a new pane"
        )
        XCTAssertEqual(
            targetWorkspace.panels.count,
            initialPanelCount + 1,
            "Expected browser panel count to increase by one"
        )
        XCTAssertEqual(
            targetWorkspace.focusedPanelId,
            browserPanelId,
            "Expected created browser panel to be focused in target workspace"
        )
        XCTAssertTrue(
            targetWorkspace.panels[browserPanelId] is BrowserTab,
            "Expected created panel to be a browser panel"
        )
    }

    func testOpenBrowserInWorkspaceSplitRightReusesTopRightPaneWhenAlreadySplit() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let topRightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              workspace.newTerminalSplit(from: topRightPanel.id, orientation: .vertical) != nil,
              let topRightPaneId = workspace.paneId(forPanelId: topRightPanel.id),
              let url = URL(string: "https://example.com/pull/456") else {
            XCTFail("Expected split setup to succeed")
            return
        }

        let initialPaneCount = workspace.bonsplitController.allPaneIds.count

        guard let browserPanelId = manager.openBrowser(
            inWorkspace: workspace.id,
            url: url,
            preferSplitRight: true,
            insertAtEnd: true
        ) else {
            XCTFail("Expected browser panel to be created")
            return
        }

        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            initialPaneCount,
            "Expected split-right browser open to reuse existing panes"
        )
        XCTAssertEqual(
            workspace.paneId(forPanelId: browserPanelId),
            topRightPaneId,
            "Expected browser to open in the top-right pane when multiple splits already exist"
        )

        let targetPaneBonsplitTabs = workspace.bonsplitController.tabs(inPane: topRightPaneId)
        guard let lastSurfaceId = targetPaneBonsplitTabs.last?.id else {
            XCTFail("Expected top-right pane to contain tabs")
            return
        }
        XCTAssertEqual(
            workspace.tabIdFromBonsplitTabId(lastSurfaceId),
            browserPanelId,
            "Expected browser surface to be appended at end in the reused top-right pane"
        )
    }
}


@MainActor
final class TabManagerEqualizeSplitsTests: XCTestCase {
    func testEqualizeSplitsSetsEverySplitDividerToHalf() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              workspace.newTerminalSplit(from: rightPanel.id, orientation: .vertical) != nil else {
            XCTFail("Expected nested split setup to succeed")
            return
        }

        let initialSplits = splitNodes(in: workspace.bonsplitController.treeSnapshot())
        XCTAssertGreaterThanOrEqual(initialSplits.count, 2, "Expected at least two split nodes in nested layout")

        for (index, split) in initialSplits.enumerated() {
            guard let splitId = UUID(uuidString: split.id) else {
                XCTFail("Expected split ID to be a UUID")
                return
            }
            let targetPosition: CGFloat = index.isMultiple(of: 2) ? 0.2 : 0.8
            XCTAssertTrue(
                workspace.bonsplitController.setDividerPosition(targetPosition, forSplit: splitId),
                "Expected to seed divider position for split \(splitId)"
            )
        }

        XCTAssertTrue(manager.equalizeSplits(workspaceId: workspace.id), "Expected equalize splits command to succeed")

        let equalizedSplits = splitNodes(in: workspace.bonsplitController.treeSnapshot())
        XCTAssertEqual(equalizedSplits.count, initialSplits.count)
        for split in equalizedSplits {
            XCTAssertEqual(split.dividerPosition, 0.5, accuracy: 0.000_1)
        }
    }

    private func splitNodes(in node: ExternalTreeNode) -> [ExternalSplitNode] {
        switch node {
        case .pane:
            return []
        case .split(let split):
            return [split] + splitNodes(in: split.first) + splitNodes(in: split.second)
        }
    }
}


@MainActor
final class TabManagerWorkspaceConfigInheritanceSourceTests: XCTestCase {
    func testUsesFocusedTerminalWhenTerminalIsFocused() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused terminal")
            return
        }

        let sourceTab = manager.terminalTabForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(sourceTab?.id, terminalPanelId)
    }

    func testFallsBackToTerminalWhenBrowserIsFocused() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: terminalPanelId),
              let browserTab = workspace.newBrowserSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected selected workspace setup to succeed")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, browserTab.id)

        let sourceTab = manager.terminalTabForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(
            sourceTab?.id,
            terminalPanelId,
            "Expected new workspace inheritance source to resolve to the pane terminal when browser is focused"
        )
    }

    func testPrefersLastFocusedTerminalAcrossPanesWhenBrowserIsFocused() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace,
              let leftTerminalPanelId = workspace.focusedPanelId,
              let rightTerminalPanel = workspace.newTerminalSplit(from: leftTerminalPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightTerminalPanel.id) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        workspace.focusPanel(leftTerminalPanelId)
        _ = workspace.newBrowserSurface(inPane: rightPaneId, focus: true)
        XCTAssertNotEqual(workspace.focusedPanelId, leftTerminalPanelId)

        let sourceTab = manager.terminalTabForWorkspaceConfigInheritanceSource()
        XCTAssertEqual(
            sourceTab?.id,
            leftTerminalPanelId,
            "Expected workspace inheritance source to use last focused terminal across panes"
        )
    }
}


@MainActor
final class TabManagerReopenClosedBrowserFocusTests: XCTestCase {
    func testReopenFromDifferentWorkspaceFocusesReopenedBrowser() {
        let manager = WorkspaceManager()
        guard let workspace1 = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/ws-switch")) else {
            XCTFail("Expected initial workspace and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closeTab(closedBrowserId, force: true))
        drainMainQueue()

        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedWorkspaceId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedWorkspaceId, workspace1.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: workspace1))
    }

    func testReopenFallsBackToCurrentWorkspaceAndFocusesBrowserWhenOriginalWorkspaceDeleted() {
        let manager = WorkspaceManager()
        guard let originalWorkspace = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/deleted-ws")) else {
            XCTFail("Expected initial workspace and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(originalWorkspace.closeTab(closedBrowserId, force: true))
        drainMainQueue()

        let currentWorkspace = manager.addWorkspace()
        manager.closeWorkspace(originalWorkspace)

        XCTAssertEqual(manager.selectedWorkspaceId, currentWorkspace.id)
        XCTAssertFalse(manager.workspaces.contains(where: { $0.id == originalWorkspace.id }))

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedWorkspaceId, currentWorkspace.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: currentWorkspace))
    }

    func testReopenCollapsedSplitFromDifferentWorkspaceFocusesBrowser() {
        let manager = WorkspaceManager()
        guard let workspace1 = manager.selectedWorkspace,
              let sourcePanelId = workspace1.focusedPanelId,
              let splitBrowserId = manager.newBrowserSplit(
                workspaceId: workspace1.id,
                fromPanelId: sourcePanelId,
                orientation: .horizontal,
                insertFirst: false,
                url: URL(string: "https://example.com/collapsed-split")
              ) else {
            XCTFail("Expected to create browser split")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closeTab(splitBrowserId, force: true))
        drainMainQueue()

        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedWorkspaceId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedWorkspaceId, workspace1.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: workspace1))
    }

    func testReopenFromDifferentWorkspaceWinsAgainstSingleDeferredStaleFocus() {
        let manager = WorkspaceManager()
        guard let workspace1 = manager.selectedWorkspace,
              let preReopenPanelId = workspace1.focusedPanelId,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/stale-focus-cross-ws")) else {
            XCTFail("Expected initial workspace state and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closeTab(closedBrowserId, force: true))
        drainMainQueue()

        let panelIdsBeforeReopen = Set(workspace1.panels.keys)
        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedWorkspaceId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        guard let reopenedPanelId = singleNewPanelId(in: workspace1, comparedTo: panelIdsBeforeReopen) else {
            XCTFail("Expected reopened browser panel ID")
            return
        }

        // Simulate one delayed stale focus callback from the panel that was focused before reopen.
        DispatchQueue.main.async {
            workspace1.focusPanel(preReopenPanelId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedWorkspaceId, workspace1.id)
        XCTAssertEqual(workspace1.focusedPanelId, reopenedPanelId)
        XCTAssertTrue(workspace1.panels[reopenedPanelId] is BrowserTab)
    }

    func testReopenInSameWorkspaceWinsAgainstSingleDeferredStaleFocus() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace,
              let preReopenPanelId = workspace.focusedPanelId,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/stale-focus-same-ws")) else {
            XCTFail("Expected initial workspace state and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace.closeTab(closedBrowserId, force: true))
        drainMainQueue()

        let panelIdsBeforeReopen = Set(workspace.panels.keys)
        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        guard let reopenedPanelId = singleNewPanelId(in: workspace, comparedTo: panelIdsBeforeReopen) else {
            XCTFail("Expected reopened browser panel ID")
            return
        }

        // Simulate one delayed stale focus callback from the panel that was focused before reopen.
        DispatchQueue.main.async {
            workspace.focusPanel(preReopenPanelId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedWorkspaceId, workspace.id)
        XCTAssertEqual(workspace.focusedPanelId, reopenedPanelId)
        XCTAssertTrue(workspace.panels[reopenedPanelId] is BrowserTab)
    }

    private func isFocusedPanelBrowser(in workspace: Workspace) -> Bool {
        guard let focusedPanelId = workspace.focusedPanelId else { return false }
        return workspace.panels[focusedPanelId] is BrowserTab
    }

    private func singleNewPanelId(in workspace: Workspace, comparedTo previousPanelIds: Set<UUID>) -> UUID? {
        let newPanelIds = Set(workspace.panels.keys).subtracting(previousPanelIds)
        guard newPanelIds.count == 1 else { return nil }
        return newPanelIds.first
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }
}

@MainActor
final class TabManagerPaneInteractionScopeTests: XCTestCase {
    /// Regression test for synthesis-critical §1.4 / synthesis-standard §1.4:
    /// `hasActivePaneInteraction` used to return true if ANY workspace had a
    /// live pane interaction. Combined with Cmd+D being selected-workspace-
    /// scoped, a dialog on a background workspace would silently render every
    /// keyboard shortcut in the active workspace inert. Must be scoped to
    /// the selected workspace only.
    func testHasActivePaneInteractionScopedToSelectedWorkspace() {
        let manager = WorkspaceManager()
        let first = manager.workspaces[0]
        let second = manager.addWorkspace()

        manager.selectWorkspace(first)
        XCTAssertEqual(manager.selectedWorkspaceId, first.id)
        XCTAssertFalse(manager.hasActivePaneInteraction)

        // Present a pane interaction on the UN-selected workspace.
        guard let secondPanelId = second.focusedPanelId else {
            XCTFail("second workspace must have a focused panel")
            return
        }
        second.paneInteractionRuntime.present(
            panelId: secondPanelId,
            interaction: .confirm(ConfirmContent(
                title: "Unseen", message: nil,
                confirmLabel: "OK", cancelLabel: "Cancel",
                role: .standard, source: .local,
                completion: { _ in }
            ))
        )

        XCTAssertFalse(
            manager.hasActivePaneInteraction,
            "Dialog on a non-selected workspace must NOT gate the selected workspace's shortcuts"
        )

        // Switch to the workspace that has the dialog — now the gate should engage.
        manager.selectWorkspace(second)
        XCTAssertTrue(manager.hasActivePaneInteraction)

        // Clear and verify flip back to false.
        second.paneInteractionRuntime.clear(panelId: secondPanelId)
        XCTAssertFalse(manager.hasActivePaneInteraction)
    }
}
