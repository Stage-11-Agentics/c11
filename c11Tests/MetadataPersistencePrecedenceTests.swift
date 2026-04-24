import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Tier 1 Phase 2: Restore path must bypass the precedence chain — the
/// snapshot IS the prior session's source of truth — but post-restore
/// writes must still respect precedence against the restored record.
final class MetadataPersistencePrecedenceTests: XCTestCase {
    private func makeStore() -> SurfaceMetadataStore {
        // Use the shared store but key off fresh UUIDs per test so parallel
        // tests don't collide on a single shared (workspace, surface) pair.
        return SurfaceMetadataStore.shared
    }

    func testRestoreInstallsExplicitAboveExistingDeclare() throws {
        let store = makeStore()
        let wsId = UUID()
        let surfaceId = UUID()

        // Pre-restore: surface has a .declare write in place (e.g. from an
        // OSC sequence the reborn terminal emitted early).
        _ = try store.setMetadata(
            workspaceId: wsId,
            surfaceId: surfaceId,
            partial: ["title": "New"],
            mode: .merge,
            source: .declare
        )

        // Restore snapshot: previous session had an .explicit title.
        store.restoreFromSnapshot(
            workspaceId: wsId,
            surfaceId: surfaceId,
            values: ["title": "From Snapshot"],
            sources: [
                "title": SurfaceMetadataStore.SourceRecord(
                    source: .explicit,
                    ts: 123.0
                )
            ]
        )

        // Snapshot wins.
        let snap = store.getMetadata(workspaceId: wsId, surfaceId: surfaceId)
        XCTAssertEqual(snap.metadata["title"] as? String, "From Snapshot")
        XCTAssertEqual(store.getSource(workspaceId: wsId, surfaceId: surfaceId, key: "title"), .explicit)
    }

    func testHeuristicWritePostRestoreCannotOverwriteRestoredExplicit() throws {
        let store = makeStore()
        let wsId = UUID()
        let surfaceId = UUID()

        store.restoreFromSnapshot(
            workspaceId: wsId,
            surfaceId: surfaceId,
            values: ["title": "Explicit Title"],
            sources: [
                "title": SurfaceMetadataStore.SourceRecord(source: .explicit, ts: 100.0)
            ]
        )

        // A heuristic write lands AFTER restore. It must be rejected by
        // precedence — .heuristic < .explicit.
        let applied = store.setInternal(
            workspaceId: wsId,
            surfaceId: surfaceId,
            key: "title",
            value: "Heuristic Title",
            source: .heuristic
        )
        XCTAssertFalse(applied, "Heuristic must not overwrite restored explicit")

        let snap = store.getMetadata(workspaceId: wsId, surfaceId: surfaceId)
        XCTAssertEqual(snap.metadata["title"] as? String, "Explicit Title")
        XCTAssertEqual(store.getSource(workspaceId: wsId, surfaceId: surfaceId, key: "title"), .explicit)
    }

    func testRestoredHeuristicKeepsHeuristicSourceAndTs() {
        let store = makeStore()
        let wsId = UUID()
        let surfaceId = UUID()

        store.restoreFromSnapshot(
            workspaceId: wsId,
            surfaceId: surfaceId,
            values: ["status": "idle"],
            sources: [
                "status": SurfaceMetadataStore.SourceRecord(source: .heuristic, ts: 42.0)
            ]
        )
        let src = store.getSource(workspaceId: wsId, surfaceId: surfaceId, key: "status")
        XCTAssertEqual(src, .heuristic)
    }

    func testExplicitWritePostRestoreUpgradesHeuristic() throws {
        let store = makeStore()
        let wsId = UUID()
        let surfaceId = UUID()

        store.restoreFromSnapshot(
            workspaceId: wsId,
            surfaceId: surfaceId,
            values: ["status": "running"],
            sources: [
                "status": SurfaceMetadataStore.SourceRecord(source: .heuristic, ts: 1.0)
            ]
        )

        // An explicit write post-restore wins over the restored heuristic.
        _ = try store.setMetadata(
            workspaceId: wsId,
            surfaceId: surfaceId,
            partial: ["status": "idle"],
            mode: .merge,
            source: .explicit
        )
        let snap = store.getMetadata(workspaceId: wsId, surfaceId: surfaceId)
        XCTAssertEqual(snap.metadata["status"] as? String, "idle")
        XCTAssertEqual(store.getSource(workspaceId: wsId, surfaceId: surfaceId, key: "status"), .explicit)
    }
}
