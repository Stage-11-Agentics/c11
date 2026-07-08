import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-162 (Telemetry truth), TEL-1 — behavior tests for metadata
/// last-updated (`ts`) stamping and its persistence round-trip.
///
/// Exercised through the real `SurfaceMetadataStore` + `PersistedMetadataBridge`
/// APIs (no source-shape / AST assertions):
///  (a) writing status/progress/task/description stamps a `ts`,
///  (b) `encodeSources` → `decodeSources` preserves `ts`,
///  (c) a value change bumps `ts` while an identical rewrite freezes it.
final class MetadataSourceTimestampTests: XCTestCase {

    private let store = SurfaceMetadataStore.shared

    // MARK: (a) Canonical writes stamp a ts

    func testCanonicalWritesStampTimestamp() throws {
        let ws = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        let before = Date().timeIntervalSince1970
        _ = try store.setMetadata(
            workspaceId: ws,
            surfaceId: surface,
            partial: [
                "status": "busy",
                "task": "build the widget",
                "description": "a longer human description",
                "progress": 0.5
            ],
            mode: .merge,
            source: .explicit
        )
        let after = Date().timeIntervalSince1970

        let got = store.getMetadata(workspaceId: ws, surfaceId: surface)
        for key in ["status", "task", "description", "progress"] {
            guard let ts = got.sources[key]?["ts"] as? Double else {
                return XCTFail("missing ts for key \(key)")
            }
            XCTAssertGreaterThanOrEqual(ts, before, "ts for \(key) predates the write")
            XCTAssertLessThanOrEqual(ts, after + 1.0, "ts for \(key) is in the future")
        }
    }

    // MARK: (b) encodeSources → decodeSources preserves ts

    func testEncodeDecodeSourcesRoundTripPreservesTimestamp() throws {
        let ws = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        _ = try store.setMetadata(
            workspaceId: ws,
            surfaceId: surface,
            partial: ["status": "busy", "task": "compile", "progress": 0.25],
            mode: .merge,
            source: .explicit
        )
        let sources = store.getMetadata(workspaceId: ws, surfaceId: surface).sources

        let persisted = PersistedMetadataBridge.encodeSources(sources)
        let decoded = PersistedMetadataBridge.decodeSources(persisted)

        for key in ["status", "task", "progress"] {
            guard let originalTs = sources[key]?["ts"] as? Double else {
                return XCTFail("missing original ts for \(key)")
            }
            guard let roundTripped = decoded[key]?.ts else {
                return XCTFail("key \(key) dropped in round-trip")
            }
            XCTAssertEqual(roundTripped, originalTs, accuracy: 0.0000001,
                           "ts for \(key) not preserved through persist round-trip")
            XCTAssertEqual(decoded[key]?.source, .explicit)
        }
    }

    // MARK: (c) value change bumps ts; identical rewrite freezes it

    func testValueChangeBumpsTimestampIdenticalRewriteFreezes() throws {
        let ws = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        _ = try store.setMetadata(
            workspaceId: ws, surfaceId: surface,
            partial: ["status": "busy"], mode: .merge, source: .explicit
        )
        let ts1 = try XCTUnwrap(
            store.getMetadata(workspaceId: ws, surfaceId: surface).sources["status"]?["ts"] as? Double
        )

        // Identical rewrite (same value + same source) must freeze the ts.
        usleep(3_000)
        _ = try store.setMetadata(
            workspaceId: ws, surfaceId: surface,
            partial: ["status": "busy"], mode: .merge, source: .explicit
        )
        let tsAfterNoOp = try XCTUnwrap(
            store.getMetadata(workspaceId: ws, surfaceId: surface).sources["status"]?["ts"] as? Double
        )
        XCTAssertEqual(tsAfterNoOp, ts1, accuracy: 0.0000001,
                       "identical rewrite must preserve the original ts")

        // A real value change must bump the ts forward.
        usleep(3_000)
        _ = try store.setMetadata(
            workspaceId: ws, surfaceId: surface,
            partial: ["status": "done"], mode: .merge, source: .explicit
        )
        let tsAfterChange = try XCTUnwrap(
            store.getMetadata(workspaceId: ws, surfaceId: surface).sources["status"]?["ts"] as? Double
        )
        XCTAssertGreaterThan(tsAfterChange, ts1,
                             "a value change must bump the ts")
    }

    // C11-162 (MAJOR-2): a persisted progress snapshot must carry its write time
    // so a restored progress bar ages from when it was written, not from restart.
    func testProgressSnapshotRoundTripsTimestamp() throws {
        let written: TimeInterval = 1_700_000_000
        let snap = SessionProgressSnapshot(value: 0.4, label: "building", timestamp: written)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(SessionProgressSnapshot.self, from: data)
        XCTAssertEqual(decoded.timestamp, written)
        XCTAssertEqual(decoded.value, 0.4)
        XCTAssertEqual(decoded.label, "building")
    }

    // Backward compatibility: a pre-C11-162 snapshot (no timestamp field) still
    // decodes, with timestamp nil (the restore path then falls back to `now`).
    func testProgressSnapshotDecodesWithoutTimestamp() throws {
        let legacy = Data(#"{"value":0.7,"label":"x"}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionProgressSnapshot.self, from: legacy)
        XCTAssertNil(decoded.timestamp)
        XCTAssertEqual(decoded.value, 0.7)
    }

    // MARK: - C11-171: set_status/set_progress mirror canonical keys, stamping ts

    /// Only agent-reportable canonical keys mirror into the evented surface
    /// store; arbitrary sidebar display chips (build/deploy) do not.
    func testSidebarCanonicalMirrorKeySelection() {
        for key in ["status", "task", "role", "model", "progress"] {
            XCTAssertEqual(TerminalController.sidebarStatusCanonicalMirrorKey(key), key,
                           "\(key) is canonical and must mirror")
        }
        for key in ["build", "deploy", "claude_code", "worktree", "activity"] {
            XCTAssertNil(TerminalController.sidebarStatusCanonicalMirrorKey(key),
                         "\(key) must stay display-only / runtime-derived")
        }
    }

    /// The set_status mirror records a canonical `ts` on the surface store so
    /// `get_metadata` sees a last-updated stamp (TEL-1) — the blocker was that
    /// set_status wrote no canonical store at all.
    func testStatusMirrorStampsTimestamp() throws {
        let ws = UUID(); let surface = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        let before = Date().timeIntervalSince1970
        XCTAssertTrue(store.setInternal(
            workspaceId: ws, surfaceId: surface,
            key: TerminalController.sidebarStatusCanonicalMirrorKey("status")!,
            value: "working", source: .explicit))
        let after = Date().timeIntervalSince1970

        let got = store.getMetadata(workspaceId: ws, surfaceId: surface)
        XCTAssertEqual(got.metadata["status"] as? String, "working")
        guard let ts = got.sources["status"]?["ts"] as? Double else {
            return XCTFail("mirrored status carries no ts")
        }
        XCTAssertGreaterThanOrEqual(ts, before)
        XCTAssertLessThanOrEqual(ts, after + 1.0)
        XCTAssertEqual(got.sources["status"]?["source"] as? String, MetadataSource.explicit.rawValue)
    }
}
