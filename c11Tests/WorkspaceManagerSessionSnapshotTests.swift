import XCTest
import Combine

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class WorkspaceManagerSessionSnapshotTests: XCTestCase {
    func testSessionSnapshotSerializesWorkspacesAndRestoreRebuildsSelection() {
        let manager = WorkspaceManager()
        guard let firstWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        firstWorkspace.setCustomTitle("First")

        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Second")
        XCTAssertEqual(manager.workspaces.count, 2)
        XCTAssertEqual(manager.selectedWorkspaceId, secondWorkspace.id)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceIndex, 1)

        let restored = WorkspaceManager()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restored.workspaces.count, 2)
        XCTAssertEqual(restored.selectedWorkspaceId, restored.workspaces[1].id)
        XCTAssertEqual(restored.workspaces[0].customTitle, "First")
        XCTAssertEqual(restored.workspaces[1].customTitle, "Second")
    }

    func testRestoreSessionSnapshotWithNoWorkspacesKeepsSingleFallbackWorkspace() {
        let manager = WorkspaceManager()
        let emptySnapshot = SessionWorkspaceManagerSnapshot(
            selectedWorkspaceIndex: nil,
            workspaces: []
        )

        manager.restoreSessionSnapshot(emptySnapshot)

        XCTAssertEqual(manager.workspaces.count, 1)
        XCTAssertNotNil(manager.selectedWorkspaceId)
    }

    func testSessionSnapshotRoundtripsWorkspaceMetadata() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        workspace.metadata = [
            WorkspaceMetadataKey.description: "Backend refactor",
            WorkspaceMetadataKey.icon: "🦊",
            "custom.tag": "v2"
        ]

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces.count, 1)
        XCTAssertEqual(snapshot.workspaces[0].metadata?["description"], "Backend refactor")
        XCTAssertEqual(snapshot.workspaces[0].metadata?["icon"], "🦊")
        XCTAssertEqual(snapshot.workspaces[0].metadata?["custom.tag"], "v2")

        let restored = WorkspaceManager()
        restored.restoreSessionSnapshot(snapshot)
        XCTAssertEqual(restored.workspaces.count, 1)
        XCTAssertEqual(restored.workspaces[0].metadata["description"], "Backend refactor")
        XCTAssertEqual(restored.workspaces[0].metadata["icon"], "🦊")
        XCTAssertEqual(restored.workspaces[0].metadata["custom.tag"], "v2")
    }

    func testEmptyMetadataIsOmittedFromSnapshot() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        XCTAssertTrue(workspace.metadata.isEmpty)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(snapshot.workspaces.first?.metadata)
    }

    func testAutosaveFingerprintChangesOnMetadataValueEdit() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        workspace.metadata = ["description": "one"]
        let before = manager.sessionAutosaveFingerprint()
        workspace.metadata = ["description": "two"]
        let after = manager.sessionAutosaveFingerprint()
        XCTAssertNotEqual(before, after,
            "Autosave fingerprint must change on value-only metadata edit (plan contract).")
    }

    func testSessionSnapshotExcludesRemoteWorkspacesFromRestore() throws {
        let manager = WorkspaceManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64001,
            relayID: "relay-test",
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let paneId = try XCTUnwrap(remoteWorkspace.bonsplitController.allPaneIds.first)
        _ = remoteWorkspace.newBrowserSurface(inPane: paneId, url: URL(string: "http://localhost:3000"), focus: false)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        XCTAssertEqual(snapshot.workspaces.count, 1)
        XCTAssertNil(snapshot.selectedWorkspaceIndex)
        XCTAssertFalse(snapshot.workspaces.contains { $0.processTitle == remoteWorkspace.title })
    }
}

extension WorkspaceManagerSessionSnapshotTests {
    func testGroupValidationAndDeletionNeverCloseOrPartiallyMoveWorkspaces() throws {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)
        let group = try manager.createWorkspaceGroup(name: "  Services  ")
        let other = try manager.createWorkspaceGroup(name: "Other")
        XCTAssertEqual(group.name, "Services")
        let originalOrder = manager.workspaces.map(\.id)
        let originalPanels = manager.workspaces.map { Set($0.panels.keys) }
        let selection = manager.selectedWorkspaceId
        try manager.addWorkspacesToGroup(id: other.id, workspaceIds: [second.id])

        for request in [[first.id, first.id], [first.id, UUID()], [first.id, second.id]] {
            XCTAssertThrowsError(try manager.addWorkspacesToGroup(id: group.id, workspaceIds: request))
            XCTAssertNil(first.groupId)
            XCTAssertEqual(second.groupId, other.id)
        }
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [first.id, third.id])
        XCTAssertThrowsError(try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [first.id])) {
            XCTAssertEqual($0 as? WorkspaceGroupOperationError, .alreadyGrouped)
        }
        XCTAssertThrowsError(try manager.removeWorkspacesFromGroup(id: group.id, workspaceIds: [first.id, second.id])) {
            XCTAssertEqual($0 as? WorkspaceGroupOperationError, .notMember)
        }
        XCTAssertEqual(first.groupId, group.id)
        try manager.setWorkspaceGroupCollapsed(id: group.id, collapsed: true)
        try manager.setWorkspaceGroupPinned(id: group.id, pinned: true)
        XCTAssertEqual(manager.selectedWorkspaceId, selection)
        try manager.deleteWorkspaceGroup(id: group.id)
        XCTAssertNil(first.groupId)
        XCTAssertNil(third.groupId)
        XCTAssertEqual(second.groupId, other.id)
        XCTAssertEqual(manager.workspaces.map(\.id), originalOrder)
        XCTAssertEqual(manager.workspaces.map { Set($0.panels.keys) }, originalPanels)
        XCTAssertEqual(manager.selectedWorkspaceId, selection)
    }

    func testGroupFocusRetainsSelectedMemberAndEmptyGroupReturnsError() throws {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: true)
        let group = try manager.createWorkspaceGroup(name: "Group")
        let empty = try manager.createWorkspaceGroup(name: "Empty")
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [first.id, second.id])
        try manager.setWorkspaceGroupCollapsed(id: group.id, collapsed: true)
        XCTAssertEqual(try manager.focusWorkspaceGroup(id: group.id), second.id)
        XCTAssertEqual(manager.selectedWorkspaceId, second.id)
        XCTAssertFalse(try XCTUnwrap(manager.workspaceGroups.first { $0.id == group.id }).isCollapsed)
        XCTAssertThrowsError(try manager.focusWorkspaceGroup(id: empty.id)) {
            XCTAssertEqual($0 as? WorkspaceGroupOperationError, .emptyGroup)
        }
        XCTAssertEqual(manager.selectedWorkspaceId, second.id)
        try manager.removeWorkspacesFromGroup(id: group.id, workspaceIds: [second.id])
        XCTAssertEqual(try manager.focusWorkspaceGroup(id: group.id), first.id)
    }

    func testBatchReorderPublishesOnceAndDryRunOrInvalidRequestsPublishNothing() throws {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)
        let group = try manager.createWorkspaceGroup(name: "Group")
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [first.id, third.id])
        var publications: [[UUID]] = []
        let subscription = manager.$workspaces.dropFirst().sink { publications.append($0.map(\.id)) }
        defer { subscription.cancel() }
        let plan = try manager.batchWorkspaceReorderPlan(orderedWorkspaceIds: [third.id, second.id])
        XCTAssertTrue(publications.isEmpty)
        XCTAssertThrowsError(try manager.applyBatchWorkspaceReorder(orderedWorkspaceIds: [first.id, UUID()]))
        XCTAssertTrue(publications.isEmpty)
        let applied = try manager.applyBatchWorkspaceReorder(orderedWorkspaceIds: [third.id, second.id])
        XCTAssertEqual(applied, plan)
        XCTAssertEqual(publications, [[third.id, second.id, first.id]])
        XCTAssertEqual(manager.selectedWorkspaceId, first.id)
        XCTAssertEqual(first.groupId, group.id)
        XCTAssertEqual(third.groupId, group.id)
        XCTAssertFalse(try manager.applyBatchWorkspaceReorder(orderedWorkspaceIds: [third.id, second.id]).changed)
        XCTAssertEqual(publications.count, 1)
    }

    func testGroupAndMemberPinsAreIndependentAndDetachClearsMembership() throws {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: false)
        let group = try manager.createWorkspaceGroup(name: "Folder")
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [first.id])
        manager.setPinned(first, pinned: true)
        XCTAssertFalse(try XCTUnwrap(manager.workspaceGroups.first).isPinned)
        try manager.setWorkspaceGroupPinned(id: group.id, pinned: true)
        try manager.setWorkspaceGroupPinned(id: group.id, pinned: false)
        XCTAssertTrue(first.isPinned)
        try manager.moveWorkspaceToGroup(workspaceId: second.id, groupId: group.id)
        XCTAssertEqual(manager.workspaces.map(\.id), [first.id, second.id])
        let detached = try XCTUnwrap(manager.detachWorkspace(workspaceId: first.id))
        XCTAssertNil(detached.groupId)
        XCTAssertTrue(detached.isPinned)
        XCTAssertEqual(manager.workspaceGroups.count, 1)
        let destination = WorkspaceManager()
        destination.attachWorkspace(detached, select: false)
        XCTAssertNil(detached.groupId)
        XCTAssertEqual(destination.workspaces.first?.id, detached.id)
        try manager.removeWorkspacesFromGroup(id: group.id, workspaceIds: [second.id])
        XCTAssertEqual(manager.workspaceGroups.count, 1)
    }

    func testGroupSnapshotMigrationRetainsSelectionAndClearsOrphans() throws {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: true)
        let group = try manager.createWorkspaceGroup(name: "Services", color: "#123456", icon: "folder.fill")
        let empty = try manager.createWorkspaceGroup(name: "Empty")
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [first.id])
        try manager.setWorkspaceGroupCollapsed(id: group.id, collapsed: true)
        var snapshot = manager.sessionSnapshot(includeScrollback: false)
        var duplicate = group
        duplicate.name = "Discarded duplicate"
        snapshot.workspaceGroups?.append(duplicate)
        snapshot.workspaces[1].groupId = UUID()
        // Corrupt legacy pin order must normalize without shifting selection by index.
        snapshot.workspaces[1].isPinned = true
        let restored = WorkspaceManager()
        restored.restoreSessionSnapshot(snapshot)
        XCTAssertEqual(restored.workspaceGroups.map(\.id), [group.id, empty.id])
        XCTAssertEqual(restored.workspaceGroups.first?.name, "Services")
        XCTAssertEqual(restored.workspaceGroups.first?.color, "#123456")
        XCTAssertEqual(restored.workspaceGroups.first?.icon, "folder.fill")
        XCTAssertEqual(restored.workspaceGroups.first?.isCollapsed, true)
        XCTAssertEqual(restored.workspaces.map(\.id), [second.id, first.id])
        XCTAssertNil(restored.workspaces.first?.groupId)
        XCTAssertEqual(restored.workspaces.last?.groupId, group.id)
        XCTAssertEqual(restored.selectedWorkspaceId, second.id)
        XCTAssertEqual(restored.sessionSnapshot(includeScrollback: false).selectedWorkspaceIndex, 0)

        // Decode an actual old workspace shape without either new key.
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        old.removeValue(forKey: "workspaceGroups")
        var workspaces = try XCTUnwrap(old["workspaces"] as? [[String: Any]])
        for index in workspaces.indices { workspaces[index].removeValue(forKey: "groupId") }
        old["workspaces"] = workspaces
        let oldSnapshot = try JSONDecoder().decode(SessionWorkspaceManagerSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        restored.restoreSessionSnapshot(oldSnapshot)
        XCTAssertTrue(restored.workspaceGroups.isEmpty)
        XCTAssertTrue(restored.workspaces.allSatisfy { $0.groupId == nil })
        XCTAssertEqual(Set(restored.workspaces.map(\.id)), Set([first.id, second.id]))
    }

    func testEveryFolderPropertyAndMembershipChangeTriggersAutosaveFingerprint() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var previous = manager.sessionAutosaveFingerprint()
        func assertChanged() {
            let current = manager.sessionAutosaveFingerprint()
            XCTAssertNotEqual(current, previous)
            previous = current
        }
        let group = try manager.createWorkspaceGroup(name: "One")
        assertChanged()
        try manager.renameWorkspaceGroup(id: group.id, name: "Two")
        assertChanged()
        try manager.setWorkspaceGroupColor(id: group.id, color: "#abcdef")
        assertChanged()
        try manager.setWorkspaceGroupIcon(id: group.id, icon: "folder.fill")
        assertChanged()
        try manager.setWorkspaceGroupCollapsed(id: group.id, collapsed: true)
        assertChanged()
        try manager.setWorkspaceGroupPinned(id: group.id, pinned: true)
        assertChanged()
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [workspace.id])
        assertChanged()
        try manager.removeWorkspacesFromGroup(id: group.id, workspaceIds: [workspace.id])
        assertChanged()
        try manager.deleteWorkspaceGroup(id: group.id)
        assertChanged()
    }
}
