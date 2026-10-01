import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class TabManagerSessionSnapshotTests: XCTestCase {
    func testSessionSnapshotSerializesWorkspacesAndRestoreRebuildsSelection() {
        let manager = TabManager()
        guard let firstWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        firstWorkspace.setCustomTitle("First")

        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Second")
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceIndex, 1)

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.selectedTabId, restored.tabs[1].id)
        XCTAssertEqual(restored.tabs[0].customTitle, "First")
        XCTAssertEqual(restored.tabs[1].customTitle, "Second")
    }

    func testRestoreSessionSnapshotWithNoWorkspacesKeepsSingleFallbackWorkspace() {
        let manager = TabManager()
        let emptySnapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: nil,
            workspaces: []
        )

        manager.restoreSessionSnapshot(emptySnapshot)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertNotNil(manager.selectedTabId)
    }

    func testSessionSnapshotRoundtripsWorkspaceMetadata() {
        let manager = TabManager()
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

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.tabs[0].metadata["description"], "Backend refactor")
        XCTAssertEqual(restored.tabs[0].metadata["icon"], "🦊")
        XCTAssertEqual(restored.tabs[0].metadata["custom.tag"], "v2")
    }

    func testEmptyMetadataIsOmittedFromSnapshot() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        XCTAssertTrue(workspace.metadata.isEmpty)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(snapshot.workspaces.first?.metadata)
    }

    func testAutosaveFingerprintChangesOnMetadataValueEdit() {
        let manager = TabManager()
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
        let manager = TabManager()
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
