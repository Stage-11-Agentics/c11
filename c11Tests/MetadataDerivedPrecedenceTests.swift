import XCTest
@testable import c11

/// C11-104 — verify that the new `.derived` precedence tier exists in
/// `MetadataSource` and sits between `.osc` and `.heuristic`.
///
/// AC13 — when an `osc` value exists, it wins over a `derived` value
/// for the same key; `derived` wins over `heuristic`.
final class MetadataDerivedPrecedenceTests: XCTestCase {

    // MARK: - Ordering

    func testDerivedRankBetweenOscAndHeuristic() {
        XCTAssertGreaterThan(MetadataSource.derived.rank, MetadataSource.heuristic.rank,
                             "derived must outrank heuristic")
        XCTAssertLessThan(MetadataSource.derived.rank, MetadataSource.osc.rank,
                          "osc must outrank derived")
        XCTAssertLessThan(MetadataSource.derived.rank, MetadataSource.declare.rank,
                          "declare must outrank derived")
        XCTAssertLessThan(MetadataSource.derived.rank, MetadataSource.explicit.rank,
                          "explicit must outrank derived")
    }

    func testDerivedRoundTripsViaRawValue() {
        XCTAssertEqual(MetadataSource(rawValue: "derived"), .derived)
        XCTAssertEqual(MetadataSource.derived.rawValue, "derived")
    }

    func testAllCasesIncludesDerived() {
        XCTAssertTrue(MetadataSource.allCases.contains(.derived))
    }

    // MARK: - SurfaceMetadataStore precedence behavior

    func testOscWinsOverDerivedForSameKey() {
        let store = SurfaceMetadataStore.shared
        let ws = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        // osc lays down first.
        let applied1 = store.setInternal(
            workspaceId: ws, surfaceId: surface,
            key: MetadataKey.branch, value: "osc-value",
            source: .osc
        )
        XCTAssertTrue(applied1)

        // derived tries to overwrite — must be rejected.
        let applied2 = store.setInternal(
            workspaceId: ws, surfaceId: surface,
            key: MetadataKey.branch, value: "derived-value",
            source: .derived
        )
        XCTAssertFalse(applied2, "derived must not overwrite osc")

        let (values, _) = store.getMetadata(workspaceId: ws, surfaceId: surface)
        XCTAssertEqual(values[MetadataKey.branch] as? String, "osc-value")
        XCTAssertEqual(store.getSource(workspaceId: ws, surfaceId: surface,
                                       key: MetadataKey.branch), .osc)
    }

    func testDerivedWinsOverHeuristic() {
        let store = SurfaceMetadataStore.shared
        let ws = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        let applied1 = store.setInternal(
            workspaceId: ws, surfaceId: surface,
            key: MetadataKey.branch, value: "heur",
            source: .heuristic
        )
        XCTAssertTrue(applied1)
        let applied2 = store.setInternal(
            workspaceId: ws, surfaceId: surface,
            key: MetadataKey.branch, value: "main",
            source: .derived
        )
        XCTAssertTrue(applied2, "derived must overwrite heuristic")

        let (values, _) = store.getMetadata(workspaceId: ws, surfaceId: surface)
        XCTAssertEqual(values[MetadataKey.branch] as? String, "main")
        XCTAssertEqual(store.getSource(workspaceId: ws, surfaceId: surface,
                                       key: MetadataKey.branch), .derived)
    }

    func testExplicitWinsOverDerived() {
        let store = SurfaceMetadataStore.shared
        let ws = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        _ = store.setInternal(
            workspaceId: ws, surfaceId: surface,
            key: MetadataKey.worktree, value: "auto-derived",
            source: .derived
        )
        let writeResult = try? store.setMetadata(
            workspaceId: ws, surfaceId: surface,
            partial: [MetadataKey.worktree: "operator-pinned"],
            mode: .merge, source: .explicit
        )
        XCTAssertEqual(writeResult?.applied[MetadataKey.worktree], true)
        XCTAssertEqual(writeResult?.metadata[MetadataKey.worktree] as? String,
                       "operator-pinned")
    }

    // MARK: - Reserved-key validation for the new canonical keys

    func testWorktreeKeyValidatesAsString() {
        let result = SurfaceMetadataStore.validateReservedKey(MetadataKey.worktree, "wt-name")
        XCTAssertNil(result, "valid worktree value must not produce a validation error")
    }

    func testBranchKeyValidatesAsString() {
        let result = SurfaceMetadataStore.validateReservedKey(MetadataKey.branch, "feature/foo")
        XCTAssertNil(result, "valid branch value must not produce a validation error")
    }

    func testWorktreeRejectsOversizeValue() {
        let huge = String(repeating: "a", count: 129)
        let result = SurfaceMetadataStore.validateReservedKey(MetadataKey.worktree, huge)
        XCTAssertNotNil(result, "worktree value over 128 chars must be rejected")
    }

    func testBranchRejectsOversizeValue() {
        let huge = String(repeating: "a", count: 65)
        let result = SurfaceMetadataStore.validateReservedKey(MetadataKey.branch, huge)
        XCTAssertNotNil(result, "branch value over 64 chars must be rejected")
    }

    // MARK: - Snapshot exclusion (plan-review B5b)

    func testDerivedKeysAreDroppedFromSnapshotCapture() {
        let metadata: [String: Any] = [
            "task": "lat-412",
            "worktree": "c11-104-sidebar-chips",
            "branch": "feat/c11-104-sidebar-chips",
        ]
        let sources: [String: [String: Any]] = [
            "task":     ["source": "declare",  "ts": 1.0],
            "worktree": ["source": "derived",  "ts": 2.0],
            "branch":   ["source": "derived",  "ts": 3.0],
        ]
        let bridged = PersistedMetadataBridge.encodeValues(
            metadata,
            surfaceIdForLog: nil,
            sources: sources
        )
        XCTAssertNotNil(bridged["task"], "non-derived keys must persist")
        XCTAssertNil(bridged["worktree"], "derived `worktree` must NOT persist")
        XCTAssertNil(bridged["branch"], "derived `branch` must NOT persist")

        let bridgedSources = PersistedMetadataBridge.encodeSources(sources)
        XCTAssertNotNil(bridgedSources["task"])
        XCTAssertNil(bridgedSources["worktree"])
        XCTAssertNil(bridgedSources["branch"])
    }

    func testEncodeValuesWithoutSourcesPreservesEverything() {
        // Back-compat: callers that don't pass sources get the old
        // "encode everything" behavior. Important so the new optional
        // parameter doesn't silently break callers that haven't been
        // updated yet.
        let metadata: [String: Any] = [
            "task": "lat-412",
            "worktree": "c11-104-sidebar-chips",
        ]
        let bridged = PersistedMetadataBridge.encodeValues(metadata, surfaceIdForLog: nil)
        XCTAssertNotNil(bridged["task"])
        XCTAssertNotNil(bridged["worktree"])
    }
}
