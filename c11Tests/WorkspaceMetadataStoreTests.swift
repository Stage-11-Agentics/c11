import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class WorkspaceMetadataStoreTests: XCTestCase {
    func testJSONRoundTripShallowMergeAndEmptyReplace() throws {
        let store = WorkspaceMetadataStore()
        let id = UUID()
        let original: [String: Any] = ["object": ["a": 1, "b": 2], "array": [true, 3, NSNull()], "null": NSNull()]
        try store.setMetadata(workspaceId: id, partial: original)
        var result = try store.setMetadata(workspaceId: id, partial: ["object": ["c": 4]])
        XCTAssertEqual(PersistedMetadataBridge.encodeValues(result.metadata), [
            "object": .object(["c": .number(4)]), "array": .array([.bool(true), .number(3), .null]), "null": .null
        ])
        result = try store.setMetadata(workspaceId: id, partial: [:], mode: .replace)
        XCTAssertTrue(result.metadata.isEmpty)
        XCTAssertEqual(result.removedKeys, ["object", "array", "null"])
    }

    func testInvalidOrOverCapWriteIsAtomicIncludingSourcesAndRevision() throws {
        let store = WorkspaceMetadataStore()
        let id = UUID()
        try store.setMetadata(workspaceId: id, partial: ["kept": "original"])
        let original = store.getMetadata(workspaceId: id)
        let revision = store.currentRevision()
        let bad: [[String: Any]] = [
            ["kept": "changed", "captain": false],
            ["kept": "changed", "icon": 4],
            ["kept": "changed", "not valid": 4],
            ["kept": "changed", "large": String(repeating: "a", count: 64 * 1024)],
            ["kept": "changed", "nan": Double.nan],
            ["kept": "changed", "date": Date()]
        ]
        for partial in bad {
            XCTAssertThrowsError(try store.setMetadata(workspaceId: id, partial: partial, mode: .replace))
            XCTAssertEqual(PersistedMetadataBridge.encodeValues(store.getMetadata(workspaceId: id).metadata),
                           PersistedMetadataBridge.encodeValues(original.metadata))
            XCTAssertEqual(PersistedMetadataBridge.encodeSources(store.getMetadata(workspaceId: id).sources),
                           PersistedMetadataBridge.encodeSources(original.sources))
            XCTAssertEqual(store.currentRevision(), revision)
        }
    }

    func testSourcePrecedenceNoOpAndSourceOnlyChange() throws {
        let store = WorkspaceMetadataStore()
        let id = UUID()
        try store.setMetadata(workspaceId: id, partial: ["value": "same"], source: .osc)
        let first = store.getMetadata(workspaceId: id)
        let revision = store.currentRevision()
        try store.setMetadata(workspaceId: id, partial: ["value": "same"], source: .osc)
        XCTAssertEqual(store.currentRevision(), revision)
        XCTAssertEqual(first.sources["value"]?["ts"] as? Double,
                       store.getMetadata(workspaceId: id).sources["value"]?["ts"] as? Double)
        let rejected = try store.setMetadata(workspaceId: id, partial: ["value": "other", "new": true], source: .heuristic)
        XCTAssertEqual(rejected.applied["value"], false)
        XCTAssertEqual(rejected.reasons["value"], "lower_precedence")
        XCTAssertEqual(rejected.applied["new"], true)
        let cleared = try store.clearMetadata(workspaceId: id, keys: ["value"], source: .heuristic)
        XCTAssertEqual(cleared.applied["value"], false)
        let beforePromotion = store.currentRevision()
        try store.setMetadata(workspaceId: id, partial: ["value": "same"], source: .explicit)
        XCTAssertGreaterThan(store.currentRevision(), beforePromotion)
        XCTAssertEqual(store.getMetadata(workspaceId: id).sources["value"]?["source"] as? String, "explicit")
        for source in [MetadataSource.declare, .osc, .heuristic] {
            XCTAssertThrowsError(try store.setMetadata(workspaceId: id, partial: [:], mode: .replace, source: source))
            XCTAssertThrowsError(try store.clearMetadata(workspaceId: id, source: source))
        }
        XCTAssertThrowsError(try store.setMetadata(workspaceId: id, partial: ["captain": "spoof"], source: .derived))
    }

    func testFileDefaultStaysSeparateAndClearRevealsLatestDefault() throws {
        let store = WorkspaceMetadataStore()
        let id = UUID()
        store.register(workspaceId: id)
        store.setCaptainDefault(workspaceId: id, address: "first", path: "/tmp/project/C11.md")
        XCTAssertEqual(store.getMetadata(workspaceId: id).sources["captain"]?["source"] as? String, "derived")
        XCTAssertTrue(store.getAuthoredMetadata(workspaceId: id).metadata.isEmpty)
        let low = try store.setMetadata(workspaceId: id, partial: ["captain": "heuristic"], source: .heuristic)
        XCTAssertEqual(low.applied["captain"], false)
        XCTAssertEqual(try store.clearMetadata(workspaceId: id, keys: ["captain"], source: .heuristic).applied["captain"], false)
        try store.setMetadata(workspaceId: id, partial: ["captain": " override "])
        store.setCaptainDefault(workspaceId: id, address: "latest", path: "/tmp/project/C11.md")
        XCTAssertEqual(store.getMetadata(workspaceId: id).metadata["captain"] as? String, "override")
        let cleared = try store.clearMetadata(workspaceId: id, keys: ["captain"])
        XCTAssertEqual(cleared.metadata["captain"] as? String, "latest")
        XCTAssertEqual(cleared.sources["captain"]?["path"] as? String, "/tmp/project/C11.md")
        XCTAssertTrue(cleared.removedKeys.isEmpty)
        store.setCaptainDefault(workspaceId: id, address: nil, path: nil)
        XCTAssertNil(store.getMetadata(workspaceId: id).metadata["captain"])
    }

    func testWholeObjectCapReplacesOldCustomCountAndStringLimits() throws {
        let store = WorkspaceMetadataStore()
        let id = UUID()
        var values: [String: Any] = Dictionary(uniqueKeysWithValues: (0..<64).map { ("custom.\($0)", "value" as Any) })
        values["large"] = String(repeating: "a", count: 4096)
        XCTAssertEqual(try store.setMetadata(workspaceId: id, partial: values).metadata.count, 65)
        let exact = ["v": String(repeating: "a", count: WorkspaceMetadataStore.payloadCapBytes - 8)]
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: exact).count, WorkspaceMetadataStore.payloadCapBytes)
        XCTAssertNoThrow(try store.setMetadata(workspaceId: id, partial: exact, mode: .replace))
        XCTAssertThrowsError(try store.setMetadata(workspaceId: id, partial: ["x": 1]))
    }

    func testCloseFenceAndSnapshotKeepWorkspacesIndependent() throws {
        let store = WorkspaceMetadataStore()
        let first = UUID(), second = UUID()
        store.register(workspaceId: first)
        store.register(workspaceId: second)
        try store.setMetadata(workspaceId: first, partial: ["captain": "one"], requireRegistered: true)
        try store.setMetadata(workspaceId: second, partial: ["captain": "two"], requireRegistered: true)
        let snapshot = store.readSnapshot()
        store.removeWorkspace(workspaceId: first)
        XCTAssertEqual(snapshot.metadata[first]?["captain"] as? String, "one")
        XCTAssertNil(store.readSnapshot().metadata[first])
        XCTAssertEqual(store.readSnapshot().metadata[second]?["captain"] as? String, "two")
        XCTAssertThrowsError(try store.setMetadata(workspaceId: first, partial: ["captain": "late"], requireRegistered: true))
        XCTAssertThrowsError(try store.clearMetadata(workspaceId: first, requireRegistered: true))
    }

    func testStaleWriteCannotReachReplacementWithSameWorkspaceUUID() throws {
        let store = WorkspaceMetadataStore()
        let id = UUID()
        let oldGeneration = store.register(workspaceId: id)
        try store.setMetadata(workspaceId: id, partial: ["captain": "old"],
                              requireRegistered: true, expectedGeneration: oldGeneration)
        store.removeWorkspace(workspaceId: id)
        let newGeneration = store.register(workspaceId: id)
        XCTAssertNotEqual(oldGeneration, newGeneration)
        XCTAssertEqual(store.registrationGeneration(workspaceId: id), newGeneration)
        try store.setMetadata(workspaceId: id, partial: ["captain": "new"],
                              requireRegistered: true, expectedGeneration: newGeneration)
        let revision = store.currentRevision()
        XCTAssertThrowsError(try store.setMetadata(workspaceId: id, partial: ["captain": "late"],
            requireRegistered: true, expectedGeneration: oldGeneration))
        XCTAssertThrowsError(try store.clearMetadata(workspaceId: id,
            requireRegistered: true, expectedGeneration: oldGeneration))
        XCTAssertEqual(store.currentRevision(), revision)
        XCTAssertEqual(store.getMetadata(workspaceId: id).metadata["captain"] as? String, "new")
    }

    @MainActor
    func testNotificationArrivesAfterCommitAndObserverCanReadStore() async throws {
        let store = WorkspaceMetadataStore()
        let id = UUID()
        let observed = expectation(description: "committed metadata")
        let token = NotificationCenter.default.addObserver(forName: WorkspaceMetadataStore.didChangeNotification,
            object: nil, queue: nil) { notification in
                guard notification.userInfo?["workspaceId"] as? UUID == id else { return }
                XCTAssertEqual(store.getMetadata(workspaceId: id).metadata["value"] as? Int, 42)
                XCTAssertEqual(notification.userInfo?["changedKeys"] as? [String], ["value"])
                observed.fulfill()
            }
        defer { NotificationCenter.default.removeObserver(token) }
        try store.setMetadata(workspaceId: id, partial: ["value": 42])
        await fulfillment(of: [observed], timeout: 1)
    }

    @MainActor
    func testRestoreNotifiesProjectionButDoesNotEmitMetadataHistory() async throws {
        for failRestore in [false, true] {
            var changes: [WorkspaceMetadataStore.Change] = []
            let store = WorkspaceMetadataStore(restoreObject: { values in
                if failRestore { throw WorkspaceMetadataStore.WriteError.encodeFailed }
                return values
            }, eventSink: { changes.append($0) })
            let id = UUID()
            store.register(workspaceId: id)
            let restored = expectation(description: "restore projection")
            let token = NotificationCenter.default.addObserver(forName: WorkspaceMetadataStore.didChangeNotification,
                object: nil, queue: nil) { notification in
                    guard notification.userInfo?["workspaceId"] as? UUID == id,
                          notification.userInfo?["source"] as? String == "restore" else { return }
                    XCTAssertEqual(store.getMetadata(workspaceId: id).metadata["description"] as? String, "saved")
                    restored.fulfill()
                }
            defer { NotificationCenter.default.removeObserver(token) }
            if failRestore {
                XCTAssertThrowsError(try store.restoreMetadata(workspaceId: id, legacy: ["description": "saved"],
                                                               values: nil, sources: nil))
            } else {
                try store.restoreMetadata(workspaceId: id, legacy: ["description": "saved"], values: nil, sources: nil)
            }
            await fulfillment(of: [restored], timeout: 1)
            // Flush the whole committed main-queue callback, including its
            // external event branch, rather than checking before it executes.
            let restoreDrained = expectation(description: "restore callback drained")
            DispatchQueue.main.async { restoreDrained.fulfill() }
            await fulfillment(of: [restoreDrained], timeout: 1)
            XCTAssertTrue(changes.isEmpty, "Restoring saved state is not a new metadata edit")

            try store.setMetadata(workspaceId: id, partial: ["description": "edited"])
            store.setCaptainDefault(workspaceId: id, address: "file-captain", path: "/tmp/fixture/C11.md")
            let writesDrained = expectation(description: "authored and derived edits drained")
            DispatchQueue.main.async { writesDrained.fulfill() }
            await fulfillment(of: [writesDrained], timeout: 1)
            XCTAssertEqual(changes.map(\.source), ["explicit", "derived"])
            XCTAssertEqual(changes.map(\.changedKeys), [["description"], ["captain"]])
        }
    }

    func testRejectionDiagnosticsContainOnlyFixedCategories() {
        let secret = "synthetic-payload-must-not-appear"
        XCTAssertEqual(WorkspaceMetadataStore.rejectionCategory(NSError(domain: secret, code: 5,
            userInfo: [NSLocalizedDescriptionKey: secret])), "metadata_restore_failed")
        XCTAssertEqual(WorkspaceMetadataStore.rejectionCategory(
            WorkspaceMetadataStore.WriteError.invalidJSON(secret)), "invalid_json")
        XCTAssertEqual(WorkspaceMetadataStore.rejectionCategory(
            WorkspaceMetadataValidator.ValidationError.invalidValue(key: secret, reason: secret)), "invalid_value")
    }
}

final class WorkspaceMetadataPersistenceTests: XCTestCase {
    /// Complete on-disk envelope, including the intentionally pinned tabManager
    /// and pane spellings, checked against main 31ab7bbc and h16 8281d12b's
    /// SessionPersistence.swift. No operator session or private data is read.
    private let legacySession = #"""
    {
      "version": 1, "createdAt": 1794614400,
      "windows": [{
        "frame": {"x": 10, "y": 20, "width": 1200, "height": 800},
        "window_id": "11111111-1111-4111-8111-111111111111", "name": "Fixture", "theme": "dark",
        "sidebar": {"isVisible": true, "selection": "tabs", "width": 240},
        "tabManager": {
          "selectedWorkspaceIndex": 0,
          "workspaces": [{
            "id": "22222222-2222-4222-8222-222222222222",
            "processTitle": "Terminal", "customTitle": "Legacy project", "customColor": "#123456",
            "isPinned": true, "currentDirectory": "/tmp/metadata-fixture",
            "rootDirectory": "/tmp/metadata-fixture", "rootAdoptionArmed": false,
            "focusedPanelId": "33333333-3333-4333-8333-333333333333",
            "layout": {"type": "pane", "pane": {
              "id": "44444444-4444-4444-8444-444444444444",
              "panelIds": ["33333333-3333-4333-8333-333333333333"],
              "selectedPanelId": "33333333-3333-4333-8333-333333333333",
              "metadata": {"mailbox.name": "fixture"},
              "metadataSources": {"mailbox.name": {"source": "explicit", "ts": 123.5}}
            }},
            "panels": [{
              "id": "33333333-3333-4333-8333-333333333333", "type": "terminal",
              "title": "Fixture shell", "directory": "/tmp/metadata-fixture",
              "isPinned": false, "isManuallyUnread": false, "listeningPorts": [],
              "terminal": {"workingDirectory": "/tmp/metadata-fixture", "scrollback": "fixture output"},
              "metadata": {"terminal_type": "shell", "custom": {"ready": true}},
              "metadataSources": {"terminal_type": {"source": "declare", "ts": 123.5}}
            }],
            "statusEntries": [], "logEntries": [],
            "metadata": {"description": "  description preserved  ", "icon": "🦊", "custom.tag": "v2", "empty": ""}
          }]
        }
      }]
    }
    """#

    private func legacySnapshot() throws -> AppSessionSnapshot {
        try JSONDecoder().decode(AppSessionSnapshot.self, from: Data(legacySession.utf8))
    }

    /// The same store snapshot seam consumed by Workspace.sessionSnapshot,
    /// encoded inside the real session envelope without constructing AppKit.
    private func capture(_ store: WorkspaceMetadataStore, in session: AppSessionSnapshot) throws -> SessionWorkspaceSnapshot {
        var session = session
        let id = session.windows[0].workspaceManager.workspaces[0].id
        let captured = store.persistenceSnapshot(workspaceId: id)
        session.windows[0].workspaceManager.workspaces[0].metadata = captured.metadata
        session.windows[0].workspaceManager.workspaces[0].metadataValues = captured.metadataValues
        session.windows[0].workspaceManager.workspaces[0].metadataSources = captured.metadataSources
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: JSONEncoder().encode(session))
        return decoded.windows[0].workspaceManager.workspaces[0]
    }

    func testFailedRestoreCaptureRetainsTypedLegacyAndProvenanceThroughLaterWrites() throws {
        var session = try legacySnapshot()
        var saved = session.windows[0].workspaceManager.workspaces[0]
        saved.metadataValues = [
            "description": .string("  typed description  "), "icon": .string("🦊"),
            "custom.tag": .string("typed custom"),
            "nested": .object(["flags": .array([.bool(true), .null, .number(3.25)])])
        ]
        saved.metadataSources = [
            "description": PersistedMetadataSource(source: "explicit", ts: 123.5),
            "icon": PersistedMetadataSource(source: "osc", ts: 124.5),
            "custom.tag": PersistedMetadataSource(source: "future-format", ts: 125.5),
            "nested": PersistedMetadataSource(source: "declare", ts: 126.5)
        ]
        session.windows[0].workspaceManager.workspaces[0] = saved
        let store = WorkspaceMetadataStore(restoreObject: { _ in
            throw WorkspaceMetadataStore.WriteError.encodeFailed
        }, eventSink: { _ in })
        store.register(workspaceId: saved.id)
        try store.setMetadata(workspaceId: saved.id, partial: ["old.live": "must disappear"])
        XCTAssertThrowsError(try store.restoreMetadata(workspaceId: saved.id, legacy: saved.metadata,
            values: saved.metadataValues, sources: saved.metadataSources))
        XCTAssertEqual(store.getMetadata(workspaceId: saved.id).metadata["description"] as? String, "  typed description  ")
        XCTAssertNil(store.getMetadata(workspaceId: saved.id).metadata["old.live"])
        var captured = try capture(store, in: session)
        XCTAssertEqual(captured.metadata, saved.metadata, "The exact original legacy projection survives")
        XCTAssertEqual(captured.metadataValues, saved.metadataValues, "All four typed fixture values survive")
        XCTAssertEqual(captured.metadataSources, saved.metadataSources, "Even unrecognized provenance is retained exactly")

        XCTAssertThrowsError(try store.setMetadata(workspaceId: saved.id, partial: ["icon": false]))
        store.setCaptainDefault(workspaceId: saved.id, address: "file-captain", path: "/tmp/fixture/C11.md")
        captured = try capture(store, in: session)
        XCTAssertEqual(captured.metadataValues, saved.metadataValues)
        XCTAssertEqual(captured.metadataSources, saved.metadataSources)
        XCTAssertEqual(captured.metadata, saved.metadata)

        try store.setMetadata(workspaceId: saved.id, partial: ["later": ["ready": true]])
        captured = try capture(store, in: session)
        var expectedValues = try XCTUnwrap(saved.metadataValues)
        expectedValues["later"] = .object(["ready": .bool(true)])
        XCTAssertEqual(captured.metadataValues, expectedValues)
        XCTAssertEqual(captured.metadata, saved.metadata)
        for (key, record) in saved.metadataSources ?? [:] { XCTAssertEqual(captured.metadataSources?[key], record) }
        XCTAssertEqual(captured.metadataSources?["later"]?.source, "explicit")
        try store.clearMetadata(workspaceId: saved.id, keys: ["custom.tag"])
        captured = try capture(store, in: session)
        XCTAssertNil(captured.metadata?["custom.tag"])
        XCTAssertNil(captured.metadataValues?["custom.tag"])
        XCTAssertNil(captured.metadataSources?["custom.tag"])
        XCTAssertEqual(captured.metadataValues?["nested"], saved.metadataValues?["nested"])
        XCTAssertEqual(captured.metadataSources?["nested"], saved.metadataSources?["nested"])

        try store.setMetadata(workspaceId: saved.id, partial: ["replacement": "intentional"], mode: .replace)
        captured = try capture(store, in: session)
        XCTAssertEqual(captured.metadataValues, ["replacement": .string("intentional")])
        XCTAssertEqual(captured.metadata, ["replacement": "intentional"])
    }

    func testFailedLegacyRestoreAndPresentEmptyTypedMapStayDistinctOnCapture() throws {
        let session = try legacySnapshot()
        let saved = session.windows[0].workspaceManager.workspaces[0]
        let variants: [[String: PersistedJSONValue]?] = [nil, [:]]
        for values in variants {
            let store = WorkspaceMetadataStore(restoreObject: { _ in throw WorkspaceMetadataStore.WriteError.encodeFailed },
                                               eventSink: { _ in })
            XCTAssertThrowsError(try store.restoreMetadata(workspaceId: saved.id, legacy: saved.metadata,
                                                           values: values, sources: nil))
            let captured = try capture(store, in: session)
            XCTAssertEqual(captured.metadata, saved.metadata)
            XCTAssertEqual(captured.metadataValues, values)
            XCTAssertNil(captured.metadataSources)
            let effectiveStrings = store.getMetadata(workspaceId: saved.id).metadata.compactMapValues { $0 as? String }
            let expectedStrings = values == nil ? (saved.metadata ?? [:]) : [:]
            XCTAssertEqual(effectiveStrings, expectedStrings)
            try store.setMetadata(workspaceId: saved.id, partial: ["later": true])
            var expected = expectedStrings.mapValues { PersistedJSONValue.string($0) }
            expected["later"] = .bool(true)
            XCTAssertEqual(try capture(store, in: session).metadataValues, expected)
            try store.clearMetadata(workspaceId: saved.id)
            let cleared = try capture(store, in: session)
            XCTAssertEqual(cleared.metadataValues, [:])
            XCTAssertNil(cleared.metadata)
        }
    }

    func testFullLegacyMainAndH16ShapeRestoresExactWorkspaceStrings() throws {
        let session = try legacySnapshot()
        let workspace = try XCTUnwrap(session.windows.first?.workspaceManager.workspaces.first)
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertEqual(workspace.panels[0].metadata?["custom"], .object(["ready": .bool(true)]))
        XCTAssertNil(workspace.metadataValues)
        let store = WorkspaceMetadataStore()
        try store.restoreMetadata(workspaceId: workspace.id, legacy: workspace.metadata,
                                  values: workspace.metadataValues, sources: workspace.metadataSources)
        let restored = store.getMetadata(workspaceId: workspace.id)
        XCTAssertEqual(restored.metadata.compactMapValues { $0 as? String }, workspace.metadata)
        XCTAssertEqual(restored.metadata["description"] as? String, "  description preserved  ")
        XCTAssertEqual(restored.metadata["icon"] as? String, "🦊")
        XCTAssertEqual(restored.metadata["custom.tag"] as? String, "v2")
        XCTAssertEqual(restored.metadata["empty"] as? String, "")
        XCTAssertTrue(restored.sources.values.allSatisfy { $0["source"] as? String == "explicit" })
        let redecoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(redecoded.windows[0].workspaceManager.workspaces[0].metadata, workspace.metadata)
    }

    func testMigrationPreservesOldCustomStringsThatNewAuthoringWouldReject() throws {
        let store = WorkspaceMetadataStore()
        let id = UUID()
        let legacy = ["custom key": "kept", "captain": "  old custom value\n", "icon": String(repeating: "x", count: 40)]
        try store.restoreMetadata(workspaceId: id, legacy: legacy, values: nil, sources: nil)
        XCTAssertEqual(store.getMetadata(workspaceId: id).metadata.compactMapValues { $0 as? String }, legacy)
        let authored = store.getAuthoredMetadata(workspaceId: id)
        let values = PersistedMetadataBridge.encodeValues(authored.metadata)
        let sources = PersistedMetadataBridge.encodeSources(authored.sources)
        let next = WorkspaceMetadataStore()
        try next.restoreMetadata(workspaceId: id, legacy: legacy, values: values, sources: sources)
        XCTAssertEqual(next.getMetadata(workspaceId: id).metadata.compactMapValues { $0 as? String }, legacy)
        XCTAssertThrowsError(try next.setMetadata(workspaceId: id, partial: legacy))
    }

    func testTypedEnvelopeAndSourcesRoundTripWithoutPersistingFileDefault() throws {
        var session = try legacySnapshot()
        var workspace = session.windows[0].workspaceManager.workspaces[0]
        let source = PersistedMetadataSource(source: "declare", ts: 12345.625)
        workspace.metadataValues = ["nested": .object(["flags": .array([.bool(true), .null, .number(3.25)])])]
        workspace.metadataSources = ["nested": source]
        session.windows[0].workspaceManager.workspaces[0] = workspace
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: JSONEncoder().encode(session))
        let restored = decoded.windows[0].workspaceManager.workspaces[0]
        let store = WorkspaceMetadataStore()
        store.register(workspaceId: restored.id)
        store.setCaptainDefault(workspaceId: restored.id, address: "from-file", path: "/tmp/metadata-fixture/C11.md")
        try store.restoreMetadata(workspaceId: restored.id, legacy: restored.metadata,
                                  values: restored.metadataValues, sources: restored.metadataSources)
        let authored = store.getAuthoredMetadata(workspaceId: restored.id)
        XCTAssertEqual(PersistedMetadataBridge.encodeValues(authored.metadata), workspace.metadataValues)
        XCTAssertEqual(PersistedMetadataBridge.encodeSources(authored.sources), workspace.metadataSources)
        XCTAssertNil(authored.metadata["description"], "Typed payload wins over stale legacy projection")
        XCTAssertNil(authored.metadata["captain"])
        XCTAssertEqual(store.getMetadata(workspaceId: restored.id).metadata["captain"] as? String, "from-file")
        let rejected = try store.setMetadata(workspaceId: restored.id, partial: ["nested": "overwrite"], source: .osc)
        XCTAssertEqual(rejected.applied["nested"], false)
    }

    func testPresentEmptyTypedMapDoesNotResurrectLegacyMetadata() throws {
        var session = try legacySnapshot()
        session.windows[0].workspaceManager.workspaces[0].metadataValues = [:]
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: JSONEncoder().encode(session))
        let workspace = decoded.windows[0].workspaceManager.workspaces[0]
        let store = WorkspaceMetadataStore()
        try store.restoreMetadata(workspaceId: workspace.id, legacy: workspace.metadata,
                                  values: workspace.metadataValues, sources: workspace.metadataSources)
        XCTAssertTrue(store.getMetadata(workspaceId: workspace.id).metadata.isEmpty)
    }

    func testBlueprintJSONRoundTripKeepsNestedWorkspaceMetadata() throws {
        let spec = WorkspaceSpec(title: "Fixture", metadata: [
            "nested": .object(["enabled": .bool(false), "list": .array([.null, .number(42)])]),
            "description": .string("kept")
        ])
        let decoded = try JSONDecoder().decode(WorkspaceSpec.self, from: JSONEncoder().encode(spec))
        XCTAssertEqual(decoded, spec)
        let legacy = try JSONDecoder().decode(WorkspaceSpec.self, from: Data(#"{"metadata":{"description":"legacy","icon":"x","custom":"kept"}}"#.utf8))
        XCTAssertEqual(legacy.metadata?["custom"], .string("kept"))
    }
}

/// C11H-299: a workspace group carries the same JSON object, through a second
/// store instance with its own scope, and persists beside its group record.
final class WorkspaceGroupMetadataStoreTests: XCTestCase {
    func testGroupStoreKeepsWorkspaceRulesAndNeverTakesAFileDefault() throws {
        var changes: [WorkspaceMetadataStore.Change] = []
        let drained = expectation(description: "group change events")
        drained.expectedFulfillmentCount = 2
        let store = WorkspaceMetadataStore(scope: .workspaceGroup, eventSink: { changes.append($0); drained.fulfill() })
        let group = UUID()
        store.register(workspaceId: group)
        try store.setMetadata(workspaceId: group, partial: ["captain": "acme-captain", "plan": ["phase": 2]])
        let lower = try store.setMetadata(workspaceId: group, partial: ["captain": "intruder"], source: .heuristic)
        XCTAssertEqual(lower.applied["captain"], false)
        XCTAssertEqual(lower.reasons["captain"], "lower_precedence")
        XCTAssertThrowsError(try store.setMetadata(workspaceId: group, partial: ["captain": "x"], source: .derived))
        XCTAssertThrowsError(try store.setMetadata(workspaceId: group, partial: ["captain": false]))
        store.setCaptainDefault(workspaceId: group, address: "file-captain", path: "/tmp/C11.md")
        try store.clearMetadata(workspaceId: group, keys: ["captain"])
        let after = store.getMetadata(workspaceId: group)
        XCTAssertNil(after.metadata["captain"], "a group has no root, so clearing reveals no C11.md default")
        XCTAssertNil(after.sources["captain"])
        XCTAssertEqual((after.metadata["plan"] as? [String: Int])?["phase"], 2)
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(changes.map(\.scope), [.workspaceGroup, .workspaceGroup])
        XCTAssertEqual(changes.last?.removedKeys, ["captain"])
    }

    func testGroupChangeNotificationNamesTheGroupNotAWorkspace() throws {
        let store = WorkspaceMetadataStore(scope: .workspaceGroup, eventSink: { _ in })
        let group = UUID()
        store.register(workspaceId: group)
        let posted = expectation(description: "group notification")
        var info: [AnyHashable: Any] = [:]
        let token = NotificationCenter.default.addObserver(forName: WorkspaceMetadataStore.didChangeNotification,
                                                           object: store, queue: .main) { note in
            info = note.userInfo ?? [:]
            posted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try store.setMetadata(workspaceId: group, partial: ["captain": "acme-captain"])
        wait(for: [posted], timeout: 2)
        XCTAssertEqual(info["groupId"] as? UUID, group)
        XCTAssertNil(info["workspaceId"], "per-workspace observers key on workspaceId and must ignore group writes")
        XCTAssertEqual(info["scope"] as? String, "workspace_group")
        XCTAssertEqual(info["changedKeys"] as? [String], ["captain"])
    }

    func testGroupEventPayloadNamesTheGroupAndOnlyChangedCanonicalValues() {
        let group = UUID()
        let payload = EventEmitter.workspaceGroupMetadataPayload(group: group, changedKeys: ["captain", "plan"],
            removedKeys: [], source: "explicit", revision: 7,
            current: ["captain": "acme-captain", "plan": ["secret": true], "description": "unchanged"],
            prior: ["description": "unchanged"])
        XCTAssertEqual(payload[EventEnvelope.PayloadKey.scope] as? String, "workspace_group")
        XCTAssertEqual(payload["group_id"] as? String, group.uuidString)
        XCTAssertEqual(payload["values"] as? [String: String], ["captain": "acme-captain"])
        XCTAssertEqual((payload["prior"] as? [String: Any])?.count, 0)
        XCTAssertEqual(payload["revision"] as? UInt64, 7)
    }

    func testTodaysSnapshotRestoresGroupsUnchangedAndSavesTheSameShape() throws {
        // The exact manager shape main wrote before group objects existed.
        let group = UUID()
        let json = ##"{"selectedWorkspaceIndex":null,"workspaces":[],"workspaceGroups":[{"id":"\##(group.uuidString)","name":"Acme","color":"#123456","icon":"folder.fill","isCollapsed":false,"isPinned":true}]}"##
        let decoded = try JSONDecoder().decode(SessionWorkspaceManagerSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(decoded.workspaceGroupMetadata)
        let groups = WorkspaceGroupProjection.restoredGroups(decoded.workspaceGroups)
        XCTAssertEqual(groups.map(\.name), ["Acme"])
        XCTAssertEqual(groups.first?.color, "#123456")
        let store = WorkspaceMetadataStore(scope: .workspaceGroup, eventSink: { _ in })
        WorkspaceGroupMetadataPersistence.restore(groups: groups, saved: decoded.workspaceGroupMetadata,
                                                  displaced: [], store: store)
        XCTAssertTrue(store.contains(workspaceId: group), "a restored group accepts writes")
        XCTAssertTrue(store.getMetadata(workspaceId: group).metadata.isEmpty)
        let saved = WorkspaceGroupMetadataPersistence.capture(groups: groups, store: store)
        XCTAssertNil(saved)
        let resaved = SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: [],
                                                      workspaceGroups: groups, workspaceGroupMetadata: saved)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(resaved)) as? [String: Any])
        XCTAssertNil(object["workspaceGroupMetadata"], "no group object means no new key on disk")
        XCTAssertEqual(try JSONDecoder().decode(SessionWorkspaceManagerSnapshot.self, from: Data(json.utf8)).workspaceGroups,
                       resaved.workspaceGroups)
    }

    func testGroupObjectRoundTripsWithSourcesAndUnknownEntriesAreDropped() throws {
        let group = WorkspaceGroup(name: "Acme")
        let writer = WorkspaceMetadataStore(scope: .workspaceGroup, eventSink: { _ in })
        writer.register(workspaceId: group.id)
        try writer.setMetadata(workspaceId: group.id, partial: ["captain": "acme-captain"])
        try writer.setMetadata(workspaceId: group.id, partial: ["plan": ["phase": 2, "done": false]], source: .declare)
        let written = writer.getMetadata(workspaceId: group.id)
        var saved = try XCTUnwrap(WorkspaceGroupMetadataPersistence.capture(groups: [group], store: writer))
        let stranger = UUID()
        saved[stranger.uuidString] = .init(metadataValues: ["captain": .string("ghost")], metadataSources: nil)
        let snapshot = SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: [],
                                                       workspaceGroups: [group], workspaceGroupMetadata: saved)
        let decoded = try JSONDecoder().decode(SessionWorkspaceManagerSnapshot.self, from: JSONEncoder().encode(snapshot))

        let reader = WorkspaceMetadataStore(scope: .workspaceGroup, eventSink: { _ in })
        WorkspaceGroupMetadataPersistence.restore(groups: WorkspaceGroupProjection.restoredGroups(decoded.workspaceGroups),
                                                  saved: decoded.workspaceGroupMetadata, displaced: [], store: reader)
        let restored = reader.getMetadata(workspaceId: group.id)
        XCTAssertEqual(PersistedMetadataBridge.encodeValues(restored.metadata), PersistedMetadataBridge.encodeValues(written.metadata))
        XCTAssertEqual(PersistedMetadataBridge.encodeSources(restored.sources), PersistedMetadataBridge.encodeSources(written.sources),
                       "sources and their timestamps survive the round trip")
        XCTAssertFalse(reader.contains(workspaceId: stranger))
        XCTAssertTrue(reader.getMetadata(workspaceId: stranger).metadata.isEmpty)
    }

    func testRestoreDropsDisplacedGroupsAndClearsStaleObjects() throws {
        let kept = WorkspaceGroup(name: "Kept"), gone = WorkspaceGroup(name: "Gone")
        let store = WorkspaceMetadataStore(scope: .workspaceGroup, eventSink: { _ in })
        for group in [kept, gone] {
            store.register(workspaceId: group.id)
            try store.setMetadata(workspaceId: group.id, partial: ["captain": "stale"])
        }
        WorkspaceGroupMetadataPersistence.restore(groups: [kept], saved: nil, displaced: [kept.id, gone.id], store: store)
        XCTAssertFalse(store.contains(workspaceId: gone.id))
        XCTAssertTrue(store.getMetadata(workspaceId: gone.id).metadata.isEmpty)
        XCTAssertTrue(store.contains(workspaceId: kept.id))
        XCTAssertTrue(store.getMetadata(workspaceId: kept.id).metadata.isEmpty,
                      "a group the snapshot saved with no object restores with none")
    }

    func testFailedGroupRestoreKeepsTheSavedFieldsForTheNextAutosave() throws {
        let group = WorkspaceGroup(name: "Acme")
        let store = WorkspaceMetadataStore(scope: .workspaceGroup,
                                           restoreObject: { _ in throw WorkspaceMetadataStore.WriteError.encodeFailed },
                                           eventSink: { _ in })
        let saved: [String: SessionWorkspaceGroupMetadataSnapshot] = [group.id.uuidString: .init(
            metadataValues: ["captain": .string("acme-captain")],
            metadataSources: ["captain": PersistedMetadataSource(source: "explicit", ts: 42)])]
        WorkspaceGroupMetadataPersistence.restore(groups: [group], saved: saved, displaced: [], store: store)
        XCTAssertEqual(WorkspaceGroupMetadataPersistence.capture(groups: [group], store: store), saved)
    }

    @MainActor
    func testResumePickerFilterKeepsGroupObjects() throws {
        let workspace = UUID(), panel = UUID()
        let group = WorkspaceGroup(name: "Acme")
        var workspaceSnapshot = SessionWorkspaceSnapshot(
            id: workspace, processTitle: "Acme web", customTitle: nil, customColor: nil, isPinned: false,
            currentDirectory: "/tmp", focusedPanelId: panel,
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: [panel], selectedPanelId: panel)),
            panels: [], statusEntries: [], logEntries: [], progress: nil, gitBranch: nil, metadata: nil)
        workspaceSnapshot.groupId = group.id
        let saved: [String: SessionWorkspaceGroupMetadataSnapshot] = [group.id.uuidString: .init(
            metadataValues: ["captain": .string("acme-captain")], metadataSources: nil)]
        let window = SessionWindowSnapshot(
            frame: nil, display: nil,
            workspaceManager: SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspaceSnapshot],
                                                              workspaceGroups: [group], workspaceGroupMetadata: saved),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240))
        let app = AppSessionSnapshot(version: 1, createdAt: 0, windows: [window])
        let filtered = try XCTUnwrap(LaunchResumePicker.filtered(snapshot: app, keep: [workspace]))
        XCTAssertEqual(filtered.windows.first?.workspaceManager.workspaceGroupMetadata, saved)
    }
}
