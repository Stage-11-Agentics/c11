import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tier 1 Phase 2: the metadataStoreRevision counter must bump on every
/// mutation that changes state, never bump on no-op writes, and remain
/// monotonic under concurrent mutation from many queues (atomicity is
/// what makes it safe to read from the autosave fingerprint tick).
final class MetadataStoreRevisionCounterTests: XCTestCase {
    private func makeStoreAndSurface() -> (SurfaceMetadataStore, UUID, UUID) {
        return (SurfaceMetadataStore.shared, UUID(), UUID())
    }

    func testSetMetadataBumpsCounter() throws {
        let (store, wsId, surfaceId) = makeStoreAndSurface()
        let before = store.currentRevision()
        _ = try store.setMetadata(
            workspaceId: wsId,
            surfaceId: surfaceId,
            partial: ["k": "v"],
            mode: .merge,
            source: .explicit
        )
        let after = store.currentRevision()
        XCTAssertEqual(after, before &+ 1)
    }

    func testSameValueSameSourceWriteDoesNotBump() throws {
        let (store, wsId, surfaceId) = makeStoreAndSurface()
        _ = try store.setMetadata(
            workspaceId: wsId,
            surfaceId: surfaceId,
            partial: ["k": "v"],
            mode: .merge,
            source: .explicit
        )
        let before = store.currentRevision()
        _ = try store.setMetadata(
            workspaceId: wsId,
            surfaceId: surfaceId,
            partial: ["k": "v"],
            mode: .merge,
            source: .explicit
        )
        XCTAssertEqual(store.currentRevision(), before,
                       "Idempotent same-value same-source write must not bump revision")
    }

    func testDifferentValueBumpsCounter() throws {
        let (store, wsId, surfaceId) = makeStoreAndSurface()
        _ = try store.setMetadata(
            workspaceId: wsId,
            surfaceId: surfaceId,
            partial: ["k": "v1"],
            mode: .merge,
            source: .explicit
        )
        let before = store.currentRevision()
        _ = try store.setMetadata(
            workspaceId: wsId,
            surfaceId: surfaceId,
            partial: ["k": "v2"],
            mode: .merge,
            source: .explicit
        )
        XCTAssertEqual(store.currentRevision(), before &+ 1)
    }

    func testLowerPrecedenceRejectionDoesNotBump() throws {
        let (store, wsId, surfaceId) = makeStoreAndSurface()
        _ = try store.setMetadata(
            workspaceId: wsId,
            surfaceId: surfaceId,
            partial: ["k": "v"],
            mode: .merge,
            source: .explicit
        )
        let before = store.currentRevision()
        _ = try store.setMetadata(
            workspaceId: wsId,
            surfaceId: surfaceId,
            partial: ["k": "v-heuristic"],
            mode: .merge,
            source: .heuristic
        )
        XCTAssertEqual(store.currentRevision(), before,
                       "Rejected lower-precedence write must not bump revision")
    }

    func testClearRemovesExistingKeyBumps() throws {
        let (store, wsId, surfaceId) = makeStoreAndSurface()
        _ = try store.setMetadata(
            workspaceId: wsId,
            surfaceId: surfaceId,
            partial: ["k": "v"],
            mode: .merge,
            source: .explicit
        )
        let before = store.currentRevision()
        _ = try store.clearMetadata(
            workspaceId: wsId,
            surfaceId: surfaceId,
            keys: ["k"],
            source: .explicit
        )
        XCTAssertEqual(store.currentRevision(), before &+ 1)
    }

    func testClearNonexistentKeyDoesNotBump() throws {
        let (store, wsId, surfaceId) = makeStoreAndSurface()
        let before = store.currentRevision()
        _ = try store.clearMetadata(
            workspaceId: wsId,
            surfaceId: surfaceId,
            keys: ["does_not_exist"],
            source: .explicit
        )
        XCTAssertEqual(store.currentRevision(), before,
                       "Clearing a non-existent key must not bump revision")
    }

    func testClearAllOnEmptyStoreDoesNotBump() throws {
        let (store, wsId, surfaceId) = makeStoreAndSurface()
        let before = store.currentRevision()
        _ = try store.clearMetadata(
            workspaceId: wsId,
            surfaceId: surfaceId,
            keys: nil,
            source: .explicit
        )
        XCTAssertEqual(store.currentRevision(), before,
                       "Clear-all against an empty store must not bump revision")
    }

    func testSetInternalBumpsOnNewKey() {
        let (store, wsId, surfaceId) = makeStoreAndSurface()
        let before = store.currentRevision()
        let applied = store.setInternal(
            workspaceId: wsId,
            surfaceId: surfaceId,
            key: "k",
            value: "v",
            source: .heuristic
        )
        XCTAssertTrue(applied)
        XCTAssertEqual(store.currentRevision(), before &+ 1)
    }

    func testSetInternalDoesNotBumpOnIdempotentWrite() {
        let (store, wsId, surfaceId) = makeStoreAndSurface()
        _ = store.setInternal(
            workspaceId: wsId,
            surfaceId: surfaceId,
            key: "k",
            value: "v",
            source: .heuristic
        )
        let before = store.currentRevision()
        _ = store.setInternal(
            workspaceId: wsId,
            surfaceId: surfaceId,
            key: "k",
            value: "v",
            source: .heuristic
        )
        XCTAssertEqual(store.currentRevision(), before)
    }

    func testRestoreFromSnapshotBumpsCounter() {
        let (store, wsId, surfaceId) = makeStoreAndSurface()
        let before = store.currentRevision()
        store.restoreFromSnapshot(
            workspaceId: wsId,
            surfaceId: surfaceId,
            values: ["k": "v"],
            sources: [
                "k": SurfaceMetadataStore.SourceRecord(source: .explicit, ts: 1.0)
            ]
        )
        XCTAssertEqual(store.currentRevision(), before &+ 1,
                       "Restore must bump so post-restore autosave picks up the change")
    }

    func testConcurrentMutationsYieldMonotonicNonDuplicateIncrements() {
        let store = SurfaceMetadataStore.shared
        let before = store.currentRevision()

        // Each iteration writes to a fresh surface so every write is a
        // genuine state change (no no-op skip). The monotonicity check
        // is what proves atomicity of the counter under contention.
        let totalWrites = 200
        let group = DispatchGroup()
        let queues: [DispatchQueue] = (0..<4).map {
            DispatchQueue(label: "test.concurrent.revision.\($0)", attributes: .concurrent)
        }
        let perQueue = totalWrites / queues.count
        for q in queues {
            for i in 0..<perQueue {
                group.enter()
                q.async {
                    _ = store.setInternal(
                        workspaceId: UUID(),
                        surfaceId: UUID(),
                        key: "k\(i)",
                        value: "v\(i)",
                        source: .heuristic
                    )
                    group.leave()
                }
            }
        }
        group.wait()
        let after = store.currentRevision()
        // Exactly one increment per genuine mutation. If the &+= were
        // non-atomic, concurrent writers could lose bumps and `after`
        // would be less than `before + totalWrites`.
        XCTAssertEqual(after, before &+ UInt64(totalWrites),
                       "Concurrent mutations must all be accounted for in the counter")
    }
}
