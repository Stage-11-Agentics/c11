import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Tier 1 persistence, Phase 1.5 — stable workspace UUIDs via restore-time ID
/// injection.
///
/// Mirrors `PanelIdentityRestoreTests` one level up: after capturing a
/// `SessionTabManagerSnapshot` and restoring it into a fresh `TabManager`,
/// each workspace's UUID must match the UUID it had in the snapshot.
/// `SurfaceMetadataStore` (Phase 2) keys on `(workspaceId, surfaceId)`, so
/// workspace ids must be stable across restart for external consumers
/// (Lattice, CLI, scripted tests) to safely cache the tuple.
@MainActor
final class WorkspaceIdentityRestoreTests: XCTestCase {
    func testSingleWorkspaceIdIsStableAcrossTabManagerRoundTrip() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let originalId = workspace.id

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces.count, 1)
        XCTAssertEqual(snapshot.workspaces.first?.id, originalId)

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(
            restored.tabs.first?.id,
            originalId,
            "Restored workspace should keep the UUID from the snapshot"
        )
    }

    func testMultipleWorkspaceIdsSurviveRoundTripWithoutCollisionOrSwap() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        first.setCustomTitle("First")
        let second = manager.addWorkspace(select: false)
        second.setCustomTitle("Second")
        let third = manager.addWorkspace(select: true)
        third.setCustomTitle("Third")

        let orderedIds = manager.tabs.map(\.id)
        XCTAssertEqual(orderedIds.count, 3)
        XCTAssertEqual(Set(orderedIds).count, 3, "Pre-snapshot workspace ids must be distinct")

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let snapshotIds = snapshot.workspaces.map(\.id)
        XCTAssertEqual(snapshotIds, orderedIds)

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredIds = restored.tabs.map(\.id)
        XCTAssertEqual(
            restoredIds,
            orderedIds,
            "Restored workspace ids should equal the pre-snapshot ids in the same order (no collision, no swap)"
        )
        XCTAssertEqual(Set(restoredIds).count, 3, "Restored workspace ids must still be distinct")

        // Workspace-scoped metadata (customTitle) must still track the correct workspace
        // after restore — a sanity check that the id stability doesn't cross ids.
        XCTAssertEqual(restored.tabs[0].customTitle, "First")
        XCTAssertEqual(restored.tabs[1].customTitle, "Second")
        XCTAssertEqual(restored.tabs[2].customTitle, "Third")
    }

    func testFallbackWorkspaceOnEmptySnapshotGetsFreshId() {
        let manager = TabManager()
        let emptySnapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: nil,
            workspaces: []
        )

        manager.restoreSessionSnapshot(emptySnapshot)

        XCTAssertEqual(manager.tabs.count, 1)
        // The empty-snapshot fallback has no snapshot id to inject; it must still
        // mint a valid fresh UUID — this guards the fallback code path at
        // TabManager.restoreSessionSnapshot.
        XCTAssertNotNil(manager.selectedTabId)
        XCTAssertEqual(manager.selectedTabId, manager.tabs.first?.id)
    }

    func testStableWorkspaceIdsPolicyIsOnByDefault() {
        XCTAssertTrue(
            SessionPersistencePolicy.stableWorkspaceIdsEnabled,
            "Phase 1.5 default: workspace IDs are stable across restarts unless CMUX_DISABLE_STABLE_WORKSPACE_IDS is set"
        )
    }
}
