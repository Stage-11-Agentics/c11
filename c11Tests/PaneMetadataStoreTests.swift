import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// CMUX-11 Phase 1: `PaneMetadataStore` parity tests. Mirrors the surface
/// store's coverage — set/get/clear, source precedence, cap enforcement,
/// revision counter, and persistence round-trip via `PersistedJSONValue`.
/// OSC/heuristic-specific tests are omitted; those sources don't apply to
/// panes in v1, but the precedence chain is still exercised end-to-end.
final class PaneMetadataStoreTests: XCTestCase {
    private func makeStoreAndPane() -> (PaneMetadataStore, UUID, UUID) {
        // Shared singleton with fresh UUIDs so parallel tests don't collide.
        return (PaneMetadataStore.shared, UUID(), UUID())
    }

    // MARK: - set / get

    func testSetMergeStoresValueAndSource() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        let result = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "Login Button"],
            mode: .merge,
            source: .explicit
        )
        XCTAssertEqual(result.applied["title"], true)
        let snap = store.getMetadata(workspaceId: wsId, paneId: paneId)
        XCTAssertEqual(snap.metadata["title"] as? String, "Login Button")
        XCTAssertEqual(store.getSource(workspaceId: wsId, paneId: paneId, key: "title"), .explicit)
    }

    func testMergePreservesOtherKeys() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "Parent :: Child"],
            mode: .merge,
            source: .explicit
        )
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["description": "review notes"],
            mode: .merge,
            source: .explicit
        )
        let snap = store.getMetadata(workspaceId: wsId, paneId: paneId)
        XCTAssertEqual(snap.metadata["title"] as? String, "Parent :: Child")
        XCTAssertEqual(snap.metadata["description"] as? String, "review notes")
    }

    func testReplaceWipesOtherKeys() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "Old", "description": "gone"],
            mode: .merge,
            source: .explicit
        )
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "New"],
            mode: .replace,
            source: .explicit
        )
        let snap = store.getMetadata(workspaceId: wsId, paneId: paneId)
        XCTAssertEqual(snap.metadata["title"] as? String, "New")
        XCTAssertNil(snap.metadata["description"])
    }

    func testReplaceRejectsNonExplicitSource() {
        let (store, wsId, paneId) = makeStoreAndPane()
        XCTAssertThrowsError(
            try store.setMetadata(
                workspaceId: wsId,
                paneId: paneId,
                partial: ["title": "X"],
                mode: .replace,
                source: .declare
            )
        )
    }

    // MARK: - precedence

    func testLowerPrecedenceMergeIsRejected() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "Explicit"],
            mode: .merge,
            source: .explicit
        )
        let result = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "Declared"],
            mode: .merge,
            source: .declare
        )
        XCTAssertEqual(result.applied["title"], false)
        XCTAssertEqual(result.reasons["title"], "lower_precedence")
        let snap = store.getMetadata(workspaceId: wsId, paneId: paneId)
        XCTAssertEqual(snap.metadata["title"] as? String, "Explicit")
    }

    func testHigherPrecedenceMergeWins() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "Declared"],
            mode: .merge,
            source: .declare
        )
        let result = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "Explicit"],
            mode: .merge,
            source: .explicit
        )
        XCTAssertEqual(result.applied["title"], true)
        let snap = store.getMetadata(workspaceId: wsId, paneId: paneId)
        XCTAssertEqual(snap.metadata["title"] as? String, "Explicit")
        XCTAssertEqual(store.getSource(workspaceId: wsId, paneId: paneId, key: "title"), .explicit)
    }

    // MARK: - clear

    func testClearSpecificKeyRemovesValue() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "T", "description": "D"],
            mode: .merge,
            source: .explicit
        )
        _ = try store.clearMetadata(
            workspaceId: wsId,
            paneId: paneId,
            keys: ["title"],
            source: .explicit
        )
        let snap = store.getMetadata(workspaceId: wsId, paneId: paneId)
        XCTAssertNil(snap.metadata["title"])
        XCTAssertEqual(snap.metadata["description"] as? String, "D")
    }

    func testClearAllRequiresExplicit() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "T"],
            mode: .merge,
            source: .explicit
        )
        XCTAssertThrowsError(
            try store.clearMetadata(
                workspaceId: wsId,
                paneId: paneId,
                keys: nil,
                source: .declare
            )
        )
    }

    // MARK: - cap enforcement

    func testOverCapWriteIsRejected() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        let big = String(repeating: "x", count: PaneMetadataStore.payloadCapBytes + 128)
        XCTAssertThrowsError(
            try store.setMetadata(
                workspaceId: wsId,
                paneId: paneId,
                partial: ["blob": big],
                mode: .merge,
                source: .explicit
            )
        )
        let snap = store.getMetadata(workspaceId: wsId, paneId: paneId)
        XCTAssertNil(snap.metadata["blob"], "Rejected over-cap write must not land")
    }

    // MARK: - revision counter

    func testSetMetadataBumpsRevisionOnce() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        let before = store.currentRevision()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "v1"],
            mode: .merge,
            source: .explicit
        )
        XCTAssertEqual(store.currentRevision(), before &+ 1)
    }

    func testIdempotentWriteDoesNotBumpRevision() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "v"],
            mode: .merge,
            source: .explicit
        )
        let before = store.currentRevision()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "v"],
            mode: .merge,
            source: .explicit
        )
        XCTAssertEqual(store.currentRevision(), before)
    }

    func testRejectedLowerPrecedenceDoesNotBump() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "Explicit"],
            mode: .merge,
            source: .explicit
        )
        let before = store.currentRevision()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "Declared"],
            mode: .merge,
            source: .declare
        )
        XCTAssertEqual(store.currentRevision(), before)
    }

    func testClearNonexistentKeyDoesNotBump() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        let before = store.currentRevision()
        _ = try store.clearMetadata(
            workspaceId: wsId,
            paneId: paneId,
            keys: ["never-set"],
            source: .explicit
        )
        XCTAssertEqual(store.currentRevision(), before)
    }

    func testClearExistingKeyBumpsRevision() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "T"],
            mode: .merge,
            source: .explicit
        )
        let before = store.currentRevision()
        _ = try store.clearMetadata(
            workspaceId: wsId,
            paneId: paneId,
            keys: ["title"],
            source: .explicit
        )
        XCTAssertEqual(store.currentRevision(), before &+ 1)
    }

    func testRestoreFromSnapshotBumpsRevision() {
        let (store, wsId, paneId) = makeStoreAndPane()
        let before = store.currentRevision()
        store.restoreFromSnapshot(
            workspaceId: wsId,
            paneId: paneId,
            values: ["title": "Restored"],
            sources: [
                "title": PaneMetadataStore.SourceRecord(source: .explicit, ts: 1.0)
            ]
        )
        XCTAssertEqual(store.currentRevision(), before &+ 1)
    }

    // MARK: - restore precedence

    func testRestoreInstallsSnapshotAboveExistingWrite() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "Newly Declared"],
            mode: .merge,
            source: .declare
        )
        store.restoreFromSnapshot(
            workspaceId: wsId,
            paneId: paneId,
            values: ["title": "From Snapshot"],
            sources: [
                "title": PaneMetadataStore.SourceRecord(source: .explicit, ts: 123.0)
            ]
        )
        let snap = store.getMetadata(workspaceId: wsId, paneId: paneId)
        XCTAssertEqual(snap.metadata["title"] as? String, "From Snapshot")
        XCTAssertEqual(store.getSource(workspaceId: wsId, paneId: paneId, key: "title"), .explicit)
    }

    func testPostRestoreLowerPrecedenceCannotOverwrite() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        store.restoreFromSnapshot(
            workspaceId: wsId,
            paneId: paneId,
            values: ["title": "Explicit Title"],
            sources: [
                "title": PaneMetadataStore.SourceRecord(source: .explicit, ts: 100.0)
            ]
        )
        let result = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "Declared Title"],
            mode: .merge,
            source: .declare
        )
        XCTAssertEqual(result.applied["title"], false)
        let snap = store.getMetadata(workspaceId: wsId, paneId: paneId)
        XCTAssertEqual(snap.metadata["title"] as? String, "Explicit Title")
    }

    // MARK: - pane / workspace lifecycle

    func testRemovePaneDropsMetadata() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "T"],
            mode: .merge,
            source: .explicit
        )
        store.removePane(workspaceId: wsId, paneId: paneId)
        // removePane is async; drain the store's queue by issuing a sync read.
        _ = store.currentRevision()
        let snap = store.getMetadata(workspaceId: wsId, paneId: paneId)
        XCTAssertTrue(snap.metadata.isEmpty)
    }

    func testPruneWorkspaceKeepsValidPanes() throws {
        let store = PaneMetadataStore.shared
        let wsId = UUID()
        let keep = UUID()
        let drop = UUID()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: keep,
            partial: ["title": "Keep"],
            mode: .merge,
            source: .explicit
        )
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: drop,
            partial: ["title": "Drop"],
            mode: .merge,
            source: .explicit
        )
        store.pruneWorkspace(workspaceId: wsId, validPaneIds: [keep])
        _ = store.currentRevision()
        XCTAssertEqual(
            store.getMetadata(workspaceId: wsId, paneId: keep).metadata["title"] as? String,
            "Keep"
        )
        XCTAssertTrue(store.getMetadata(workspaceId: wsId, paneId: drop).metadata.isEmpty)
    }

    // MARK: - persistence round-trip

    /// Tier 1 Phase 2's persistence rails (`PersistedJSONValue` /
    /// `PersistedMetadataSource`) are reused for panes in Phase 3. Round-trip
    /// through the bridge here so the scaffolding ships with confidence the
    /// Phase 3 decode path will work.
    func testSnapshotRoundTripViaPersistedJSONBridge() throws {
        let (store, wsId, paneId) = makeStoreAndPane()
        _ = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: [
                "title": "Login :: Review",
                "description": "breadcrumb"
            ],
            mode: .merge,
            source: .explicit
        )
        let snap = store.getMetadata(workspaceId: wsId, paneId: paneId)
        let encodedValues = PersistedMetadataBridge.encodeValues(snap.metadata)
        let encodedSources = PersistedMetadataBridge.encodeSources(snap.sources)

        let valuesData = try JSONEncoder().encode(encodedValues)
        let sourcesData = try JSONEncoder().encode(encodedSources)
        let decodedValues = try JSONDecoder().decode(
            [String: PersistedJSONValue].self, from: valuesData
        )
        let decodedSources = try JSONDecoder().decode(
            [String: PersistedMetadataSource].self, from: sourcesData
        )

        // Install into a fresh pane via the restore path.
        let restoredPane = UUID()
        store.restoreFromSnapshot(
            workspaceId: wsId,
            paneId: restoredPane,
            values: PersistedMetadataBridge.decodeValues(decodedValues),
            sources: PersistedMetadataBridge.decodeSources(decodedSources)
        )
        let restored = store.getMetadata(workspaceId: wsId, paneId: restoredPane)
        XCTAssertEqual(restored.metadata["title"] as? String, "Login :: Review")
        XCTAssertEqual(restored.metadata["description"] as? String, "breadcrumb")
        XCTAssertEqual(
            store.getSource(workspaceId: wsId, paneId: restoredPane, key: "title"),
            .explicit
        )
    }

    // MARK: - setInternal

    func testSetInternalBumpsOnNewKey() {
        let (store, wsId, paneId) = makeStoreAndPane()
        let before = store.currentRevision()
        let applied = store.setInternal(
            workspaceId: wsId,
            paneId: paneId,
            key: "role",
            value: "sub-agent",
            source: .declare
        )
        XCTAssertTrue(applied)
        XCTAssertEqual(store.currentRevision(), before &+ 1)
    }

    func testSetInternalDoesNotBumpOnIdempotentWrite() {
        let (store, wsId, paneId) = makeStoreAndPane()
        _ = store.setInternal(
            workspaceId: wsId,
            paneId: paneId,
            key: "role",
            value: "sub-agent",
            source: .declare
        )
        let before = store.currentRevision()
        _ = store.setInternal(
            workspaceId: wsId,
            paneId: paneId,
            key: "role",
            value: "sub-agent",
            source: .declare
        )
        XCTAssertEqual(store.currentRevision(), before)
    }

    // MARK: - concurrency

    func testConcurrentMutationsYieldMonotonicCounter() {
        let store = PaneMetadataStore.shared
        let before = store.currentRevision()

        let totalWrites = 200
        let group = DispatchGroup()
        let queues: [DispatchQueue] = (0..<4).map {
            DispatchQueue(label: "test.pane.metadata.revision.\($0)", attributes: .concurrent)
        }
        let perQueue = totalWrites / queues.count
        for q in queues {
            for i in 0..<perQueue {
                group.enter()
                q.async {
                    _ = store.setInternal(
                        workspaceId: UUID(),
                        paneId: UUID(),
                        key: "k\(i)",
                        value: "v\(i)",
                        source: .declare
                    )
                    group.leave()
                }
            }
        }
        group.wait()
        let after = store.currentRevision()
        XCTAssertEqual(
            after, before &+ UInt64(totalWrites),
            "Concurrent mutations must all be accounted for in the counter"
        )
    }
}
