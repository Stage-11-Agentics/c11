import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// CMUX-11 Phase 3: Codable round-trip + bridge / cap behaviour for the
/// pane-side persistence layer added on top of `SessionPaneLayoutSnapshot`.
/// Mirrors `MetadataPersistenceRoundTripTests` but keys on panes instead of
/// surfaces. End-to-end save/load via the live workspace + bonsplit tree is
/// covered by the Python socket test in `tests_v2/test_pane_metadata_persistence.py`.
final class PaneMetadataPersistenceTests: XCTestCase {
    // MARK: - SessionPaneLayoutSnapshot Codable backcompat

    func testPrePhase3SnapshotDecodesCleanlyWithoutMetadataFields() throws {
        // Pre-Phase-3 snapshots only carried `panelIds` + `selectedPanelId`.
        // Phase 3 added `id`, `metadata`, and `metadataSources` as optionals;
        // older snapshots must still decode and surface nil for the new fields.
        let panelIds = [UUID().uuidString, UUID().uuidString]
        let legacyJSON = """
        {
            "panelIds": ["\(panelIds[0])", "\(panelIds[1])"]
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionPaneLayoutSnapshot.self, from: legacyJSON)
        XCTAssertEqual(decoded.panelIds.map { $0.uuidString }, panelIds)
        XCTAssertNil(decoded.selectedPanelId)
        XCTAssertNil(decoded.id)
        XCTAssertNil(decoded.metadata)
        XCTAssertNil(decoded.metadataSources)
    }

    func testPhase3SnapshotRoundTripPreservesIdMetadataAndSources() throws {
        let paneId = UUID()
        let panelIds = [UUID()]
        let metadata: [String: PersistedJSONValue] = [
            "title": .string("Login Button :: MA Review"),
            "progress": .number(0.42),
            "active": .bool(true),
            "tags": .array([.string("claude"), .string("code")])
        ]
        let sources: [String: PersistedMetadataSource] = [
            "title": PersistedMetadataSource(source: "explicit", ts: 1_700_000_001),
            "progress": PersistedMetadataSource(source: "declare", ts: 1_700_000_002),
            "active": PersistedMetadataSource(source: "heuristic", ts: 1_700_000_003),
            "tags": PersistedMetadataSource(source: "osc", ts: 1_700_000_004)
        ]
        let snapshot = SessionPaneLayoutSnapshot(
            panelIds: panelIds,
            selectedPanelId: panelIds.first,
            id: paneId,
            metadata: metadata,
            metadataSources: sources
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionPaneLayoutSnapshot.self, from: data)
        XCTAssertEqual(decoded.id, paneId)
        XCTAssertEqual(decoded.panelIds, panelIds)
        XCTAssertEqual(decoded.selectedPanelId, panelIds.first)
        XCTAssertEqual(decoded.metadata, metadata)
        XCTAssertEqual(decoded.metadataSources, sources)
    }

    func testEmptyPaneMetadataEmitsAsNilToKeepSnapshotsSmall() throws {
        let snapshot = SessionPaneLayoutSnapshot(
            panelIds: [],
            selectedPanelId: nil,
            id: UUID(),
            metadata: nil,
            metadataSources: nil
        )
        let data = try JSONEncoder().encode(snapshot)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"metadata\""))
        XCTAssertFalse(json.contains("\"metadataSources\""))
    }

    // MARK: - Bridge helpers (pane label)

    func testEnforcePaneSizeCapDropsOversizedKeysUntilUnderLimit() {
        let cap = SurfaceMetadataStore.payloadCapBytes
        // Two big strings that together exceed the cap; the largest-first
        // policy must drop the bigger one and leave the smaller intact.
        let bigger = String(repeating: "a", count: cap)
        let smaller = String(repeating: "b", count: 4096)
        let values: [String: PersistedJSONValue] = [
            "huge": .string(bigger),
            "small": .string(smaller)
        ]
        let capped = PersistedMetadataBridge.enforceSizeCap(
            values,
            entityKind: "pane",
            entityId: UUID()
        )
        XCTAssertNil(capped["huge"], "Largest key must be dropped to fit cap")
        XCTAssertNotNil(capped["small"], "Smaller key must survive")
        let encoded = try? JSONEncoder().encode(capped)
        XCTAssertNotNil(encoded)
        XCTAssertLessThanOrEqual(encoded?.count ?? Int.max, cap)
    }

    // MARK: - Restore path cap enforcement (CMUX-11 acceptance #4)

    /// Restore must reject snapshot entries whose persisted blob exceeds the
    /// 64 KiB per-pane cap, silently and largest-first, so a hand-edited or
    /// version-skewed snapshot cannot rehydrate over-cap state into the live
    /// store. Tests the bridge call shape that `Workspace.restorePaneMeta-
    /// dataFromSnapshot` exercises, plus that the surviving metadata installs
    /// while the dropped key's sidecar is filtered out alongside it.
    func testRestoreCapDropsOversizedKeyAndAlignsSources() throws {
        let cap = SurfaceMetadataStore.payloadCapBytes
        let huge = String(repeating: "a", count: cap)
        let persistedValues: [String: PersistedJSONValue] = [
            "title": .string("Parent :: Restored"),
            "blob": .string(huge)
        ]
        let persistedSources: [String: PersistedMetadataSource] = [
            "title": PersistedMetadataSource(source: "explicit", ts: 100),
            "blob": PersistedMetadataSource(source: "declare", ts: 101)
        ]

        let cappedValues = PersistedMetadataBridge.enforceSizeCap(
            persistedValues,
            entityKind: "pane",
            entityId: UUID()
        )
        XCTAssertNil(cappedValues["blob"], "Over-cap key must be dropped on restore")
        XCTAssertNotNil(cappedValues["title"], "Under-cap key must survive")

        let alignedSources = persistedSources.filter { cappedValues.keys.contains($0.key) }
        XCTAssertNil(alignedSources["blob"], "Sidecar for dropped key must be filtered")
        XCTAssertEqual(alignedSources["title"]?.source, "explicit")

        // Install through the live store using the same call shape the
        // restore path uses, then read back to confirm only the survivor
        // landed and its source attribution is preserved.
        let store = PaneMetadataStore.shared
        let wsId = UUID()
        let paneId = UUID()
        let values = PersistedMetadataBridge.decodeValues(cappedValues)
        let sources = PersistedMetadataBridge.decodeSources(alignedSources)
        store.restoreFromSnapshot(
            workspaceId: wsId,
            paneId: paneId,
            values: values,
            sources: sources
        )
        let snap = store.getMetadata(workspaceId: wsId, paneId: paneId)
        XCTAssertEqual(snap.metadata["title"] as? String, "Parent :: Restored")
        XCTAssertNil(snap.metadata["blob"])
        XCTAssertEqual(store.getSource(workspaceId: wsId, paneId: paneId, key: "title"), .explicit)
    }

    // MARK: - Restore precedence on PaneMetadataStore

    func testRestoreFromSnapshotPreservesNonExplicitSourceAttribution() throws {
        let store = PaneMetadataStore.shared
        let wsId = UUID()
        let paneId = UUID()
        // Snapshot carries a `.declare` value — restoring must NOT stamp it
        // `.explicit` wholesale, otherwise a subsequent `.declare` write
        // would be incorrectly soft-rejected.
        store.restoreFromSnapshot(
            workspaceId: wsId,
            paneId: paneId,
            values: ["title": "Declared Title"],
            sources: [
                "title": PaneMetadataStore.SourceRecord(source: .declare, ts: 1.0)
            ]
        )
        XCTAssertEqual(
            store.getSource(workspaceId: wsId, paneId: paneId, key: "title"),
            .declare,
            "Restore must preserve original source attribution, not promote to explicit"
        )

        // Equal-precedence write is allowed.
        let same = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "Still Declared"],
            mode: .merge,
            source: .declare
        )
        XCTAssertEqual(same.applied["title"], true)

        // Lower-precedence write is rejected.
        let lower = try store.setMetadata(
            workspaceId: wsId,
            paneId: paneId,
            partial: ["title": "Heuristic guess"],
            mode: .merge,
            source: .heuristic
        )
        XCTAssertEqual(lower.applied["title"], false)
        XCTAssertEqual(lower.reasons["title"], "lower_precedence")
    }
}
