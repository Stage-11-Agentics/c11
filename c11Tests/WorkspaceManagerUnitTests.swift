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

@MainActor
final class AgentPIDAttentionCleanupTests: XCTestCase {
    func testScopedClearWorkerPreservesSiblingAndFocus() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let caller = try XCTUnwrap(workspace.focusedPanelId)
        let sibling = UUID()
        let controller = TerminalController.shared
        let oldManager = controller.workspaceManager
        controller.workspaceManager = manager
        let store = TerminalNotificationStore.shared
        defer {
            store.replaceNotificationsForTesting([])
            controller.workspaceManager = oldManager
        }
        store.replaceNotificationsForTesting([notice(workspace.id, caller), notice(workspace.id, sibling)])
        let command = "clear_notifications --tab=\(workspace.id) --panel=\(caller)"
        XCTAssertEqual(controller.processCommandUsingSocketExecutionPolicy(command), "OK")
        drainMainQueue()
        XCTAssertFalse(store.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: caller))
        XCTAssertTrue(store.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: sibling))
        XCTAssertEqual(workspace.focusedPanelId, caller)

        XCTAssertTrue(controller.processCommandUsingSocketExecutionPolicy(
            "clear_notifications --tab=\(workspace.id) --panel="
        ).hasPrefix("ERROR:"))
        XCTAssertEqual(controller.processCommandUsingSocketExecutionPolicy(
            "clear_notifications --tab=\(workspace.id) --panel=\(UUID())"
        ), "OK")
        drainMainQueue()
        XCTAssertTrue(store.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: sibling))
    }

    func testPIDCommandDoesNotAssociateFocusedTabWithoutExplicitSelector() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let caller = try XCTUnwrap(workspace.focusedPanelId)
        let controller = TerminalController.shared
        let oldManager = controller.workspaceManager
        controller.workspaceManager = manager
        defer { controller.workspaceManager = oldManager }
        XCTAssertEqual(controller.setAgentPID("caller 101 --tab=\(workspace.id) --panel=\(caller)"), "OK")
        drainMainQueue()
        XCTAssertEqual(workspace.removeAgentPID(key: "caller"), caller)

        XCTAssertEqual(controller.setAgentPID("caller 102 --tab=\(workspace.id)"), "OK")
        drainMainQueue()
        XCTAssertNil(workspace.removeAgentPID(key: "caller"))
    }

    func testDeadAttributedPIDClearsOnlyItsTab() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let caller = try XCTUnwrap(workspace.focusedPanelId)
        let sibling = UUID()
        let store = TerminalNotificationStore.shared
        defer { store.replaceNotificationsForTesting([]) }
        store.replaceNotificationsForTesting([notice(workspace.id, caller), notice(workspace.id, sibling)])
        workspace.registerAgentPID(101, key: "caller", tabId: caller)
        workspace.statusEntries["caller"] = SidebarStatusEntry(key: "caller", value: "Needs input")

        manager.sweepStaleAgentPIDs(isRunning: { _ in false }, notificationStore: store)

        XCTAssertNil(workspace.agentPIDs["caller"])
        XCTAssertNil(workspace.statusEntries["caller"])
        XCTAssertFalse(store.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: caller))
        XCTAssertTrue(store.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: sibling))
        XCTAssertEqual(store.unreadCount(forWorkspaceId: workspace.id), 1)
    }

    func testReplacementWithoutAttributionPreservesEveryNotice() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let caller = try XCTUnwrap(workspace.focusedPanelId)
        let store = TerminalNotificationStore.shared
        defer { store.replaceNotificationsForTesting([]) }
        store.replaceNotificationsForTesting([notice(workspace.id, caller)])
        workspace.registerAgentPID(101, key: "caller", tabId: caller)
        workspace.registerAgentPID(102, key: "caller", tabId: nil)

        manager.sweepStaleAgentPIDs(isRunning: { _ in false }, notificationStore: store)

        XCTAssertTrue(store.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: caller))
        XCTAssertNil(workspace.agentPIDs["caller"])
    }

    func testLivePIDAndUnknownTabPreserveAttention() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let caller = try XCTUnwrap(workspace.focusedPanelId)
        let store = TerminalNotificationStore.shared
        defer { store.replaceNotificationsForTesting([]) }
        store.replaceNotificationsForTesting([notice(workspace.id, caller)])
        workspace.registerAgentPID(101, key: "live", tabId: caller)
        workspace.registerAgentPID(102, key: "unknown", tabId: UUID())

        manager.sweepStaleAgentPIDs(isRunning: { $0 == 101 }, notificationStore: store)

        XCTAssertTrue(store.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: caller))
        XCTAssertEqual(workspace.agentPIDs["live"], 101)
        XCTAssertNil(workspace.agentPIDs["unknown"])
    }

    func testResetRemovesPriorPIDAttribution() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let caller = try XCTUnwrap(workspace.focusedPanelId)
        workspace.registerAgentPID(101, key: "caller", tabId: caller)
        workspace.clearAgentPIDs()
        // A legacy writer must not inherit the prior process's tab association.
        workspace.agentPIDs["caller"] = 101
        XCTAssertNil(workspace.removeAgentPID(key: "caller"))
    }

    private func notice(_ workspace: UUID, _ tab: UUID) -> TerminalNotification {
        TerminalNotification(id: UUID(), workspaceId: workspace, surfaceId: tab,
                             title: "Synthetic attention", subtitle: "Waiting", body: "",
                             createdAt: Date(), isRead: false)
    }
}

func drainMainQueue() {
    let expectation = XCTestExpectation(description: "drain main queue")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTWaiter().wait(for: [expectation], timeout: 5.0)
}

@MainActor
final class WorkspaceManagerChildExitCloseTests: XCTestCase {
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
final class WorkspaceManagerWorkspaceOwnershipTests: XCTestCase {
    func testCloseWorkspaceIgnoresWorkspaceNotOwnedByManager() throws {
        let owner = WorkspaceManager()
        let ownedWorkspace = owner.addWorkspace()
        let other = WorkspaceManager()
        _ = other.addWorkspace()
        let ownerIds = owner.workspaces.map(\.id)
        let otherIds = other.workspaces.map(\.id)
        let ownerSelection = owner.selectedWorkspaceId
        let otherSelection = other.selectedWorkspaceId
        let panelIdentities = ownedWorkspace.panels.mapValues { ObjectIdentifier($0 as AnyObject) }
        let titles = ownedWorkspace.tabTitles
        XCTAssertFalse(panelIdentities.isEmpty)
        XCTAssertTrue(ownedWorkspace.owningWorkspaceManager === owner)

        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let store = TerminalNotificationStore.shared
        let originalStore = appDelegate.notificationStore
        let originalNotifications = store.notifications
        appDelegate.notificationStore = store
        defer {
            store.replaceNotificationsForTesting(originalNotifications)
            appDelegate.notificationStore = originalStore
        }
        let notification = TerminalNotification(
            id: UUID(), workspaceId: ownedWorkspace.id, surfaceId: ownedWorkspace.focusedPanelId,
            title: "Synthetic ownership notification", subtitle: "", body: "",
            createdAt: Date(), isRead: false
        )
        store.replaceNotificationsForTesting([notification])

        other.closeWorkspace(ownedWorkspace)

        XCTAssertEqual(owner.workspaces.map(\.id), ownerIds)
        XCTAssertEqual(other.workspaces.map(\.id), otherIds)
        XCTAssertEqual(owner.selectedWorkspaceId, ownerSelection)
        XCTAssertEqual(other.selectedWorkspaceId, otherSelection)
        XCTAssertEqual(ownedWorkspace.panels.mapValues { ObjectIdentifier($0 as AnyObject) }, panelIdentities)
        XCTAssertEqual(ownedWorkspace.tabTitles, titles)
        XCTAssertTrue(ownedWorkspace.owningWorkspaceManager === owner)
        XCTAssertEqual(store.notifications.map(\.id), [notification.id])

        owner.closeWorkspace(ownedWorkspace)
        XCTAssertEqual(owner.workspaces.map(\.id), ownerIds.filter { $0 != ownedWorkspace.id })
        XCTAssertEqual(owner.selectedWorkspaceId, ownerIds.first)
        XCTAssertTrue(ownedWorkspace.panels.isEmpty)
        XCTAssertNil(ownedWorkspace.owningWorkspaceManager)
        XCTAssertTrue(store.notifications.isEmpty)
        XCTAssertEqual(other.workspaces.map(\.id), otherIds)
    }

    func testStaleManagerCannotCloseWorkspaceAfterDetachAndAttach() throws {
        let source = WorkspaceManager()
        _ = source.addWorkspace()
        let moved = source.addWorkspace()
        let destination = WorkspaceManager()
        _ = destination.addWorkspace()
        let identities = moved.panels.mapValues { ObjectIdentifier($0 as AnyObject) }
        let titles = moved.tabTitles

        let detached = try XCTUnwrap(source.detachWorkspace(workspaceId: moved.id))
        XCTAssertTrue(detached === moved)
        XCTAssertEqual(moved.panels.mapValues { ObjectIdentifier($0 as AnyObject) }, identities)
        destination.attachWorkspace(detached)
        let sourceIds = source.workspaces.map(\.id)
        let destinationIds = destination.workspaces.map(\.id)
        let sourceSelection = source.selectedWorkspaceId
        let destinationSelection = destination.selectedWorkspaceId
        XCTAssertGreaterThan(sourceIds.count, 1, "exercise ownership, not the last-workspace guard")

        source.closeWorkspace(moved)

        XCTAssertEqual(source.workspaces.map(\.id), sourceIds)
        XCTAssertEqual(destination.workspaces.map(\.id), destinationIds)
        XCTAssertEqual(source.selectedWorkspaceId, sourceSelection)
        XCTAssertEqual(destination.selectedWorkspaceId, destinationSelection)
        XCTAssertEqual(moved.panels.mapValues { ObjectIdentifier($0 as AnyObject) }, identities)
        XCTAssertEqual(moved.tabTitles, titles)
        XCTAssertTrue(moved.owningWorkspaceManager === destination)

        destination.closeWorkspace(moved)
        XCTAssertFalse(destination.workspaces.contains { $0.id == moved.id })
        XCTAssertTrue(moved.panels.isEmpty)
        XCTAssertNil(moved.owningWorkspaceManager)
    }

    func testDirectCloseKeepsLastWorkspaceAndPanels() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.workspaces.first)
        let identities = workspace.panels.mapValues { ObjectIdentifier($0 as AnyObject) }
        manager.closeWorkspace(workspace)
        XCTAssertEqual(manager.workspaces.map(\.id), [workspace.id])
        XCTAssertEqual(manager.selectedWorkspaceId, workspace.id)
        XCTAssertEqual(workspace.panels.mapValues { ObjectIdentifier($0 as AnyObject) }, identities)
        XCTAssertTrue(workspace.owningWorkspaceManager === manager)
    }

    func testCloseResolvesOwnedInstanceForMatchingWorkspaceId() {
        let manager = WorkspaceManager()
        let owned = manager.addWorkspace()
        let alias = Workspace(id: owned.id, title: "Synthetic alternate instance")
        let aliasIdentities = alias.panels.mapValues { ObjectIdentifier($0 as AnyObject) }
        manager.closeWorkspace(alias)
        XCTAssertFalse(manager.workspaces.contains { $0.id == owned.id })
        XCTAssertTrue(owned.panels.isEmpty)
        XCTAssertNil(owned.owningWorkspaceManager)
        XCTAssertEqual(alias.panels.mapValues { ObjectIdentifier($0 as AnyObject) }, aliasIdentities)
    }

}


@MainActor
final class WorkspaceManagerCloseWorkspacesWithConfirmationTests: XCTestCase {
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
        manager.selectWorkspace(foreground)
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
final class WorkspaceManagerCloseCurrentPanelTests: XCTestCase {
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

    func testCloseTabButtonClosesWorkspaceWhenItOwnsTheLastTab() {
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

    func testCloseTabButtonStillClosesWorkspaceWhenKeepWorkspaceOpenPreferenceIsEnabled() {
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

    func testGenericCloseTabKeepsWorkspaceOpenWithoutExplicitCloseMarker() {
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
final class WorkspaceManagerNotificationFocusTests: XCTestCase {
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
final class WorkspaceManagerPendingUnfocusPolicyTests: XCTestCase {
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
final class WorkspaceManagerSurfaceCreationTests: XCTestCase {
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
final class WorkspaceManagerEqualizeSplitsTests: XCTestCase {
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
final class WorkspaceManagerWorkspaceConfigInheritanceSourceTests: XCTestCase {
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
final class WorkspaceManagerReopenClosedBrowserFocusTests: XCTestCase {
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
final class WorkspaceManagerAreaInteractionScopeTests: XCTestCase {
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

@MainActor
final class TerminalControllerRefLifecycleTests: XCTestCase {
    func testKnownRefsSeedOnlyOnceAndOnlyAfterInitialRestoreIsReady() throws {
        _ = try XCTUnwrap(AppDelegate.shared)
        let controller = TerminalController.makeForTesting()
        controller.setInitialSessionRestoreReady(false)
        controller.v2RefreshKnownRefs()
        XCTAssertEqual(controller.debugKnownRefSeedCount, 0)
        XCTAssertTrue(controller.v2RefByUUID.values.allSatisfy(\.isEmpty))

        controller.setInitialSessionRestoreReady(true)
        controller.v2RefreshKnownRefs()
        XCTAssertEqual(controller.debugKnownRefSeedCount, 1)
        for _ in 0..<100 {
            for method in ["system.ping", "system.capabilities"] {
                let response = controller.processV2Command("{\"id\":297,\"method\":\"\(method)\"}")
                let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
                XCTAssertEqual(result["ok"] as? Bool, true)
            }
            // Worker entry points may still invoke the idempotent fallback.
            controller.v2RefreshKnownRefs()
        }
        XCTAssertEqual(controller.debugKnownRefSeedCount, 1,
                       "Worker requests must not repeat the startup graph walk")
    }

    func testPublishedAdditionsRegisterSuppliedNewIDsBeforeCreationReturns() throws {
        let controller = TerminalController.shared
        let manager = WorkspaceManager()
        defer { manager.workspaces.forEach { $0.teardownAllPanels() } }
        var publishedWorkspaceIds: Set<UUID> = []
        let workspaceSubscription = manager.$workspaces.sink { newWorkspaces in
            for workspace in newWorkspaces where !manager.workspaces.contains(where: { $0.id == workspace.id }) {
                publishedWorkspaceIds.insert(workspace.id)
            }
        }
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        XCTAssertTrue(publishedWorkspaceIds.contains(workspace.id))
        // Combine does not promise subscriber order. All synchronous willSet
        // deliveries must finish before the next command can use the result.
        XCTAssertNotNil(controller.v2RefByUUID[.workspace]?[workspace.id])
        let root = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        XCTAssertNotNil(controller.v2RefByUUID[.pane]?[root.id])

        var publishedTabIds: Set<UUID> = []
        let panelSubscription = workspace.$panels.sink { newPanels in
            for id in newPanels.keys where workspace.panels[id] == nil {
                publishedTabIds.insert(id)
            }
        }
        let browser = try XCTUnwrap(workspace.newBrowserSurface(inPane: root, focus: false))
        XCTAssertTrue(publishedTabIds.contains(browser.id))
        XCTAssertNotNil(controller.v2RefByUUID[.surface]?[browser.id],
                        "Ref registration must consume newPanels, not the old workspace.panels")
        withExtendedLifetime((workspaceSubscription, panelSubscription)) {}
    }

    func testSplitMoveAndClosePreserveRefsWithoutReseeding() throws {
        let controller = TerminalController.shared
        let source = WorkspaceManager()
        let destination = WorkspaceManager()
        defer {
            source.workspaces.forEach { $0.teardownAllPanels() }
            destination.workspaces.forEach { $0.teardownAllPanels() }
        }
        let workspace = source.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let initialTab = try XCTUnwrap(workspace.panels.keys.first)
        let split = try XCTUnwrap(workspace.newTerminalSplit(from: initialTab, orientation: .horizontal))
        let area = try XCTUnwrap(workspace.paneId(forPanelId: split.id))
        let areaRef = try XCTUnwrap(controller.v2RefByUUID[.pane]?[area.id])
        let tabRef = try XCTUnwrap(controller.v2RefByUUID[.surface]?[split.id])
        let workspaceRef = try XCTUnwrap(controller.v2RefByUUID[.workspace]?[workspace.id])
        let seedCount = controller.debugKnownRefSeedCount

        let detachedTab = try XCTUnwrap(workspace.detachTab(panelId: split.id))
        let target = destination.workspaces[0]
        let targetArea = try XCTUnwrap(target.bonsplitController.allPaneIds.first)
        XCTAssertEqual(target.attachDetachedTab(detachedTab, inPane: targetArea, focus: false), split.id)
        XCTAssertEqual(controller.v2RefByUUID[.surface]?[split.id], tabRef)
        XCTAssertTrue(target.closeTab(split.id, force: true))
        XCTAssertNil(target.panels[split.id])
        XCTAssertEqual(controller.v2ResolveHandleRef(tabRef), split.id,
                       "Closed refs remain tombstones instead of being recycled")
        XCTAssertEqual(controller.v2ResolveHandleRef(areaRef), area.id)

        let movedWorkspace = try XCTUnwrap(source.detachWorkspace(workspaceId: workspace.id))
        destination.attachWorkspace(movedWorkspace, select: false)
        XCTAssertEqual(controller.v2RefByUUID[.workspace]?[workspace.id], workspaceRef)
        destination.closeWorkspace(movedWorkspace)
        XCTAssertEqual(controller.v2ResolveHandleRef(workspaceRef), workspace.id)
        let nextWorkspace = source.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        XCTAssertNotEqual(controller.v2RefByUUID[.workspace]?[nextWorkspace.id], workspaceRef)
        XCTAssertEqual(controller.debugKnownRefSeedCount, seedCount,
                       "Lifecycle hooks must not enumerate the global graph")
    }

    func testSnapshotRestoreRegistersNewAreasAndRetainsRestoredTabRefs() throws {
        let controller = TerminalController.shared
        let original = Workspace()
        let restored = Workspace()
        defer {
            original.teardownAllPanels()
            restored.teardownAllPanels()
        }
        let initialTab = try XCTUnwrap(original.panels.keys.first)
        _ = try XCTUnwrap(original.newTerminalSplit(from: initialTab, orientation: .horizontal))
        let snapshot = original.sessionSnapshot(includeScrollback: false, conversationsByPanelId: [:])
        let tabRefs = Dictionary(uniqueKeysWithValues: try snapshot.panels.map { panel in
            (panel.id, try XCTUnwrap(controller.v2RefByUUID[.surface]?[panel.id]))
        })
        let seedCount = controller.debugKnownRefSeedCount
        restored.restoreSessionSnapshot(snapshot)
        XCTAssertEqual(Set(restored.panels.keys), Set(tabRefs.keys))
        XCTAssertEqual(restored.bonsplitController.allPaneIds.count, 2)
        for area in restored.bonsplitController.allPaneIds {
            XCTAssertNotNil(controller.v2RefByUUID[.pane]?[area.id])
        }
        for (id, ref) in tabRefs {
            XCTAssertEqual(controller.v2RefByUUID[.surface]?[id], ref)
        }
        XCTAssertEqual(controller.debugKnownRefSeedCount, seedCount)
    }
}

@MainActor
final class StartupBundledReportsTests: XCTestCase {
    func testBundledBashAndZshOneShotReportsSurvivePendingRestoreWithoutRetry() async throws {
#if DEBUG
        let app = try XCTUnwrap(AppDelegate.shared)
        let originalManager = app.workspaceManager
        let manager = WorkspaceManager()
        // Keep the fixture detached from any window, so no real terminal can
        // mount and race these synthetic sender reports. Publish its graph
        // only at the readiness transition, after the asynchronous senders.
        defer {
            app.workspaceManager = originalManager
            manager.workspaces.forEach { $0.teardownAllPanels() }
        }
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let bashTab = try XCTUnwrap(workspace.focusedPanelId)
        let zshTab = try XCTUnwrap(workspace.newTerminalSurfaceInFocusedPane(focus: false)).id
        let controller = TerminalController.makeForTesting()
        let originalPortsCallback = PortScanner.shared.onPortsUpdated
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("c11-startup-reports-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            controller.stop()
            PortScanner.shared.onPortsUpdated = originalPortsCallback
            try? FileManager.default.removeItem(at: root)
        }
        let socketPath = root.appendingPathComponent("control.sock").path
        controller.setInitialSessionRestoreReady(false)
        controller.start(workspaceManager: manager, socketPath: socketPath, accessMode: .allowAll)
        XCTAssertTrue(controller.isListeningForStartupRestore)
        XCTAssertEqual(controller.socketPathSnapshot, socketPath)

        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let cases: [(shell: String, resource: String, panel: UUID, tty: String)] = [
            ("/bin/bash", "cmux-bash-integration.bash", bashTab, "ttysC11297bash"),
            ("/bin/zsh", "cmux-zsh-integration.zsh", zshTab, "ttysC11297zsh")
        ]
        for item in cases {
            XCTAssertNil(workspace.tabTTYNames[item.panel])
            XCTAssertFalse(workspace.tabNeedsConfirmClose(panelId: item.panel, fallbackNeedsConfirmClose: false))
            let resource = repository.appendingPathComponent("Resources/shell-integration/\(item.resource)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: resource.path), "Bundled source must be present")
            let output = try await runBundledReports(
                shell: item.shell, resource: resource, panel: item.panel,
                tty: item.tty, socketPath: socketPath, root: root
            )
            XCTAssertTrue(output.contains("cached:1:running"),
                          "The real sender must already have cached both reports and exited: \(output)")
        }

        // Each shipped sender launches disowned, one-way nc writes. Observe
        // actual socket admission instead of assuming sender exit means receipt.
        let deadline = Date().addingTimeInterval(5)
        while controller.debugDeferredStartupReportCount < 4 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(controller.debugDeferredStartupReportCount, 4,
                       "Both real shells must deliver one TTY and one activity report before readiness")
        for item in cases {
            XCTAssertNil(workspace.tabTTYNames[item.panel], "Pending reports must not touch the partial graph")
            XCTAssertFalse(workspace.tabNeedsConfirmClose(panelId: item.panel, fallbackNeedsConfirmClose: false),
                           "Running activity must remain unapplied while restoration is pending")
        }

        // No sender remains to retry after this transition. Flush must apply
        // both accepted one-shot reports synchronously to the installed graph.
        // Host window callbacks can replace the active manager across awaits;
        // install this detached fixture now, with no suspension before flush.
        app.workspaceManager = manager
        for item in cases {
            let located = try XCTUnwrap(app.workspaceContainingPanel(
                panelId: item.panel, preferredWorkspaceId: item.panel
            ))
            XCTAssertTrue(located.workspace === workspace)
            XCTAssertTrue(located.workspaceManager === manager)
        }
        controller.setInitialSessionRestoreReady(true)
        XCTAssertEqual(controller.debugDeferredStartupReportCount, 0)
        for item in cases {
            XCTAssertEqual(workspace.tabTTYNames[item.panel], item.tty)
            XCTAssertTrue(workspace.tabNeedsConfirmClose(panelId: item.panel, fallbackNeedsConfirmClose: false),
                          "The accepted running state must affect observable close policy without sender retry")
        }
#else
        throw XCTSkip("Deferred startup report inspection is debug-only")
#endif
    }

    private func runBundledReports(
        shell: String, resource: URL, panel: UUID, tty: String, socketPath: String, root: URL
    ) async throws -> String {
        let outputURL = root.appendingPathComponent("\(URL(fileURLWithPath: shell).lastPathComponent).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        let script = """
        source "$1" || exit 31
        _CMUX_TTY_NAME="$2"
        _cmux_report_tty_once
        _cmux_report_shell_activity_state running
        printf 'cached:%s:%s\\n' "$_CMUX_TTY_REPORTED" "$_CMUX_SHELL_ACTIVITY_LAST"
        """
        let options = shell == "/bin/bash" ? ["--noprofile", "--norc"] : ["-f"]
        process.arguments = options + ["-c", script, "c11-startup-reports", resource.path, tty]
        process.environment = [
            "PATH": "/usr/bin:/bin", // Real bundled _cmux_send uses macOS nc, never a shim.
            "HOME": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            // These are intentionally the legacy values exported to real
            // shells: --tab carries the panel ID, not the workspace UUID.
            "CMUX_TAB_ID": panel.uuidString,
            "CMUX_PANEL_ID": panel.uuidString
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !process.isRunning else {
            throw NSError(domain: "StartupBundledReportsTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled \(shell) sender exceeded its deadline"])
        }
        let result = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0, "\(shell): \(result)")
        return result
    }
}

/// Regression for the background-agent browser-proof workspace interruptions.
@MainActor
final class AgentWorkspaceSelectionTests: XCTestCase {
    func testSocketSelectionDoesNotPublishOrSwitchAndOperatorStillCan() throws {
        _ = NSApplication.shared
        let manager = WorkspaceManager()
        let original = try XCTUnwrap(manager.selectedWorkspaceId)
        let target = manager.addWorkspace(select: false)
        var publications = 0
        let subscription = manager.$storedSelectedWorkspaceId.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        let context = SocketCommandContext(method: "workspace.select", allowsFocus: true, callerTabId: UUID())
        SocketCommandContext.withContext(context) { manager.selectWorkspace(target) }
        XCTAssertEqual(manager.selectedWorkspaceId, original)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(context.blockedTarget, target.id)
        manager.selectWorkspace(target, cause: "sidebar")
        XCTAssertEqual(manager.selectedWorkspaceId, target.id)
        XCTAssertEqual(publications, 1)
    }

    func testSocketDispatcherReturnsRefusalForBothWireVersions() throws {
        _ = NSApplication.shared
        let manager = WorkspaceManager()
        let original = try XCTUnwrap(manager.selectedWorkspaceId)
        let target = manager.addWorkspace(select: false)
        let controller = TerminalController.shared
        let savedManager = controller.workspaceManager
        controller.workspaceManager = manager
        defer { controller.workspaceManager = savedManager }
        let request: [String: Any] = ["id": 323, "method": "workspace.select",
            "params": ["workspace_id": target.id.uuidString, "caller_tab_id": UUID().uuidString]]
        let data = try JSONSerialization.data(withJSONObject: request)
        let reply = controller.processCommandUsingSocketExecutionPolicy(String(decoding: data, as: UTF8.self))
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["ok"] as? Bool, false)
        XCTAssertEqual((decoded["error"] as? [String: Any])?["code"] as? String, "workspace_switch_blocked")
        XCTAssertTrue(controller.processCommandUsingSocketExecutionPolicy("select_workspace \(target.id.uuidString)")
            .contains("workspace_switch_blocked"))
        XCTAssertEqual(manager.selectedWorkspaceId, original)
    }

    func testSocketCloseCannotRemoveVisibleWorkspace() throws {
        _ = NSApplication.shared
        let manager = WorkspaceManager()
        let original = try XCTUnwrap(manager.selectedWorkspace)
        _ = manager.addWorkspace(select: false)
        let context = SocketCommandContext(method: "workspace.close", allowsFocus: false)
        SocketCommandContext.withContext(context) { manager.closeWorkspace(original) }
        XCTAssertEqual(manager.selectedWorkspaceId, original.id)
        XCTAssertTrue(manager.workspaces.contains { $0.id == original.id })
        XCTAssertNotNil(context.blockedTarget)
    }

    func testCloseUsesSeenHistoryInsteadOfIndexNeighbour() throws {
        _ = NSApplication.shared
        let manager = WorkspaceManager()
        let original = try XCTUnwrap(manager.selectedWorkspace)
        let recent = manager.addWorkspace(select: false)
        let neighbour = manager.addWorkspace(select: false)
        manager.workspaces = [original, neighbour, recent]
        // Runtime history fixture: last-seen UUID beats an index neighbour.
        let snapshot = FocusHistorySnapshot(entries: [
            FocusHistoryEntry(workspaceId: recent.id, panelId: UUID(), seenAt: Date(), dwell: 2)
        ], index: 0)
        XCTAssertEqual(manager.closeFallback(excluding: original.id, index: 0, history: snapshot), recent.id)
        XCTAssertEqual(manager.closeFallback(excluding: original.id, index: 0,
            history: FocusHistorySnapshot(entries: [], index: nil)), neighbour.id)
        manager.closeWorkspace(original)
        XCTAssertTrue(manager.workspaces.contains { $0.id == neighbour.id })
    }
}
