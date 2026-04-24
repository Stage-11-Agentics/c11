import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Tier 1 Phase 2 round-trip coverage for the PersistedJSONValue /
/// SessionPanelSnapshot encode/decode layer. All tests go through
/// JSONEncoder/Decoder so they verify the actual wire format, not just
/// in-memory Swift equality.
final class MetadataPersistenceRoundTripTests: XCTestCase {
    // MARK: - PersistedJSONValue

    func testPrimitiveTypesRoundTrip() throws {
        let cases: [PersistedJSONValue] = [
            .string("hello"),
            .string(""),
            .number(0),
            .number(42),
            .number(-1.5),
            .number(Double.greatestFiniteMagnitude),
            .bool(true),
            .bool(false),
            .null
        ]
        for value in cases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(PersistedJSONValue.self, from: data)
            XCTAssertEqual(decoded, value, "Round-trip changed \(value)")
        }
    }

    func testBoolStaysBoolNotNumber() throws {
        // Regression guard for the Bool/NSNumber ordering bug. Once encoded as
        // JSON `true`, decode must produce .bool not .number(1).
        let data = try JSONEncoder().encode(PersistedJSONValue.bool(true))
        let decoded = try JSONDecoder().decode(PersistedJSONValue.self, from: data)
        guard case .bool(let b) = decoded else {
            XCTFail("Expected .bool, got \(decoded)")
            return
        }
        XCTAssertTrue(b)
    }

    func testNumberStaysNumberNotBool() throws {
        // Symmetric guard: integer-valued numbers must not be coerced to bool.
        let data = try JSONEncoder().encode(PersistedJSONValue.number(1))
        let decoded = try JSONDecoder().decode(PersistedJSONValue.self, from: data)
        guard case .number(let d) = decoded else {
            XCTFail("Expected .number, got \(decoded)")
            return
        }
        XCTAssertEqual(d, 1.0)
    }

    func testNestedArrayRoundTrip() throws {
        let value: PersistedJSONValue = .array([
            .string("a"),
            .number(1),
            .bool(true),
            .null,
            .array([.number(2), .number(3)])
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(PersistedJSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testNestedObjectRoundTrip() throws {
        let value: PersistedJSONValue = .object([
            "title": .string("Hello"),
            "progress": .number(0.42),
            "done": .bool(false),
            "tags": .array([.string("one"), .string("two")]),
            "nested": .object([
                "deeper": .object([
                    "deepest": .string("bottom")
                ])
            ])
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(PersistedJSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // MARK: - PersistedMetadataSource

    func testSourceRecordRoundTrip() throws {
        let record = PersistedMetadataSource(source: "explicit", ts: 1_700_000_000.5)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(PersistedMetadataSource.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    func testAllKnownSourceRawValuesRoundTrip() throws {
        for source in MetadataSource.allCases {
            let record = PersistedMetadataSource(source: source.rawValue, ts: 1.0)
            let data = try JSONEncoder().encode(record)
            let decoded = try JSONDecoder().decode(PersistedMetadataSource.self, from: data)
            XCTAssertEqual(decoded.source, source.rawValue)
        }
    }

    // MARK: - SessionPanelSnapshot backcompat

    func testPrePhase2SnapshotDecodesCleanlyWithoutMetadataFields() throws {
        // A snapshot written by a pre-Phase-2 build has no `metadata` or
        // `metadataSources` keys at all. It must decode without error; both
        // fields must come back as nil.
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "type": "terminal",
            "isPinned": false,
            "isManuallyUnread": false,
            "listeningPorts": []
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionPanelSnapshot.self, from: legacyJSON)
        XCTAssertNil(decoded.metadata)
        XCTAssertNil(decoded.metadataSources)
    }

    func testPhase2SnapshotRoundTripPreservesMetadata() throws {
        let panelId = UUID()
        let metadata: [String: PersistedJSONValue] = [
            "title": .string("Frontend"),
            "progress": .number(0.5),
            "active": .bool(true),
            "tags": .array([.string("claude"), .string("code")])
        ]
        let sources: [String: PersistedMetadataSource] = [
            "title": PersistedMetadataSource(source: "explicit", ts: 1_700_000_001),
            "progress": PersistedMetadataSource(source: "osc", ts: 1_700_000_002),
            "active": PersistedMetadataSource(source: "heuristic", ts: 1_700_000_003),
            "tags": PersistedMetadataSource(source: "declare", ts: 1_700_000_004)
        ]
        let snapshot = SessionPanelSnapshot(
            id: panelId,
            type: .terminal,
            title: nil,
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: nil,
            browser: nil,
            markdown: nil,
            metadata: metadata,
            metadataSources: sources
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionPanelSnapshot.self, from: data)
        XCTAssertEqual(decoded.id, panelId)
        XCTAssertEqual(decoded.metadata, metadata)
        XCTAssertEqual(decoded.metadataSources, sources)
    }

    func testEmptyMetadataEmitsAsNilToKeepSnapshotsSmall() throws {
        // If every panel has an empty store, snapshot should not bloat with
        // empty dicts. The capture path assigns nil; verify the encoded JSON
        // omits both keys entirely.
        let snapshot = SessionPanelSnapshot(
            id: UUID(),
            type: .terminal,
            title: nil,
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: nil,
            browser: nil,
            markdown: nil,
            metadata: nil,
            metadataSources: nil
        )
        let data = try JSONEncoder().encode(snapshot)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"metadata\""))
        XCTAssertFalse(json.contains("\"metadataSources\""))
    }

    // MARK: - Bridge encode/decode helpers

    func testBridgeEncodeDecodeValuesIsSymmetric() {
        let original: [String: Any] = [
            "s": "hello",
            "n": 42,
            "b": true,
            "null": NSNull(),
            "arr": [1, "two", false] as [Any],
            "obj": ["nested": "yes"]
        ]
        let encoded = PersistedMetadataBridge.encodeValues(original)
        let decoded = PersistedMetadataBridge.decodeValues(encoded)
        XCTAssertEqual(decoded["s"] as? String, "hello")
        XCTAssertEqual((decoded["n"] as? Double).map { Int($0) }, 42)
        XCTAssertEqual(decoded["b"] as? Bool, true)
        XCTAssertTrue(decoded["null"] is NSNull)
        let arr = decoded["arr"] as? [Any]
        XCTAssertEqual(arr?.count, 3)
        let obj = decoded["obj"] as? [String: Any]
        XCTAssertEqual(obj?["nested"] as? String, "yes")
    }

    func testBridgeSourceDecodeDowngradesUnknownSource() {
        let unknown = PersistedMetadataSource(source: "not_a_real_source", ts: 999)
        let decoded = PersistedMetadataBridge.decodeSources(["k": unknown])
        XCTAssertEqual(decoded["k"]?.source, .heuristic)
        XCTAssertEqual(decoded["k"]?.ts, 999)
    }
}
