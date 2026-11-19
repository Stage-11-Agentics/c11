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

    private let store = PanelMetadataStore.shared

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

    // MARK: - C11H-278: the description's edit time

    private func descriptionTs(_ ws: UUID, _ surface: UUID) throws -> Double {
        try XCTUnwrap(store.getMetadata(workspaceId: ws, surfaceId: surface).sources["description"]?["ts"] as? Double)
    }

    /// The same text from another source keeps the edit time (the source still
    /// moves); new text moves it. A re-set must not make a stale description
    /// look fresh.
    func testSameDescriptionFromAnotherSourceKeepsItsEditTime() throws {
        let ws = UUID(); let surface = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        _ = try store.setMetadata(workspaceId: ws, surfaceId: surface,
                                  partial: ["description": "Auditing retries"], mode: .merge, source: .declare)
        let edited = try descriptionTs(ws, surface)

        usleep(3_000)
        _ = try store.setMetadata(workspaceId: ws, surfaceId: surface,
                                  partial: ["description": "Auditing retries"], mode: .merge, source: .explicit)
        XCTAssertEqual(try descriptionTs(ws, surface), edited, accuracy: 0.0000001,
                       "same text, new source: the edit time stays")
        XCTAssertEqual(store.getSource(workspaceId: ws, surfaceId: surface, key: "description"), .explicit)

        usleep(3_000)
        XCTAssertFalse(store.setInternal(workspaceId: ws, surfaceId: surface, key: "description",
                                         value: "Auditing retries", source: .explicit), "an identical rewrite is a no-op")
        _ = try store.setMetadata(workspaceId: ws, surfaceId: surface,
                                  partial: ["description": "Auditing retries"], mode: .replace, source: .explicit)
        XCTAssertEqual(try descriptionTs(ws, surface), edited, accuracy: 0.0000001,
                       "a replace that keeps the text keeps the edit time")

        usleep(3_000)
        _ = try store.setMetadata(workspaceId: ws, surfaceId: surface,
                                  partial: ["description": "Verifying cancellation"], mode: .merge, source: .explicit)
        XCTAssertGreaterThan(try descriptionTs(ws, surface), edited, "new text moves the edit time")
        let updatedAt = try XCTUnwrap(store.descriptionUpdatedAt(workspaceId: ws, surfaceId: surface))
        XCTAssertEqual(updatedAt.timeIntervalSince1970, try descriptionTs(ws, surface), accuracy: 0.0000001)
    }

    /// The single-key setter follows the same rule.
    func testSetInternalSameDescriptionFromAnotherSourceKeepsItsEditTime() throws {
        let ws = UUID(); let surface = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }

        XCTAssertTrue(store.setInternal(workspaceId: ws, surfaceId: surface, key: "description",
                                        value: "Awaiting first task", source: .heuristic))
        let edited = try descriptionTs(ws, surface)
        usleep(3_000)
        XCTAssertTrue(store.setInternal(workspaceId: ws, surfaceId: surface, key: "description",
                                        value: "Awaiting first task", source: .declare))
        XCTAssertEqual(try descriptionTs(ws, surface), edited, accuracy: 0.0000001)
    }

    /// The edit time survives a session save and restore, and a cleared
    /// description has none.
    func testDescriptionEditTimeSurvivesRestoreAndClears() throws {
        let ws = UUID(); let surface = UUID(); let restored = UUID()
        defer {
            store.removeSurface(workspaceId: ws, surfaceId: surface)
            store.removeSurface(workspaceId: ws, surfaceId: restored)
        }
        _ = try store.setMetadata(workspaceId: ws, surfaceId: surface,
                                  partial: ["description": "Shipping the bar"], mode: .merge, source: .explicit)
        let original = try XCTUnwrap(store.descriptionUpdatedAt(workspaceId: ws, surfaceId: surface))
        let live = store.getMetadata(workspaceId: ws, surfaceId: surface)

        let encoded = try JSONEncoder().encode(PersistedMetadataBridge.encodeSources(live.sources))
        let persisted = try JSONDecoder().decode([String: PersistedMetadataSource].self, from: encoded)
        store.restoreFromSnapshot(workspaceId: ws, surfaceId: restored, values: live.metadata,
                                  sources: PersistedMetadataBridge.decodeSources(persisted))
        let afterRestore = try XCTUnwrap(store.descriptionUpdatedAt(workspaceId: ws, surfaceId: restored))
        XCTAssertEqual(afterRestore.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 0.0000001)

        _ = try store.clearMetadata(workspaceId: ws, surfaceId: restored, keys: ["description"], source: .explicit)
        XCTAssertNil(store.descriptionUpdatedAt(workspaceId: ws, surfaceId: restored))
    }

    /// A record without a real time (a persisted 0) has no edit time, so
    /// every reader agrees on null rather than one showing 1970.
    func testARecordWithoutARealTimeHasNoEditTime() {
        let ws = UUID(); let surface = UUID()
        defer { store.removeSurface(workspaceId: ws, surfaceId: surface) }
        store.restoreFromSnapshot(workspaceId: ws, surfaceId: surface, values: ["description": "Restored"],
                                  sources: ["description": PanelMetadataStore.SourceRecord(source: .explicit, ts: 0)])
        XCTAssertNil(store.descriptionUpdatedAt(workspaceId: ws, surfaceId: surface))
        XCTAssertNil(PanelMetadataStore.editTime(ts: 0))
        XCTAssertNotNil(PanelMetadataStore.editTime(ts: 1_800_000_000))
    }

    /// The socket fields: local time with its offset and whole seconds, or nulls.
    func testDescriptionAgeSocketFields() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fields = Workspace.descriptionAgeFields(updatedAt: now.addingTimeInterval(-754), now: now)
        XCTAssertEqual(fields["description_age_seconds"] as? Int, 754)
        let stamp = try XCTUnwrap(fields["description_updated_at"] as? String)
        XCTAssertEqual(stamp, PanelLineageNode.localTimestamp(now.addingTimeInterval(-754)))
        XCTAssertNotNil(stamp.range(of: #"[+-]\d\d:\d\d$"#, options: .regularExpression), "local offset, never Z")

        let none = Workspace.descriptionAgeFields(updatedAt: nil, now: now)
        XCTAssertTrue(none["description_updated_at"] is NSNull)
        XCTAssertTrue(none["description_age_seconds"] is NSNull)
    }
    // MARK: C11H-296: card context revision

    /// The sidebar rebuilds a card's agent rows when this revision moves: on a
    /// new or cleared description, or an agent panel's new title; never on the
    /// same text again, on keys the row does not show, or on a title no row
    /// shows (a shell's or a TUI's).
    func testCardContextRevisionMovesOnlyWhenTitleOrDescriptionChanges() throws {
        let ws = UUID(), other = UUID(), agent = UUID(), shell = UUID()
        defer {
            store.removeWorkspace(workspaceId: ws)
            store.removeWorkspace(workspaceId: other)
        }
        func write(_ surface: UUID, _ partial: [String: Any], source: MetadataSource = .explicit) throws {
            _ = try store.setMetadata(workspaceId: ws, surfaceId: surface, partial: partial,
                                      mode: .merge, source: source)
        }
        func revision() -> UInt64 { store.cardContextRevision(workspaceId: ws) }
        XCTAssertEqual(revision(), 0)

        try write(agent, ["description": "Auditing retry admission"])
        let described = revision()
        XCTAssertNotEqual(described, 0, "a new description moves the revision")

        try write(agent, ["description": "Auditing retry admission"])
        XCTAssertEqual(revision(), described, "the same text again is no change")
        try write(agent, ["status": "busy", "progress": 0.5, "task": "build the widget"])
        try write(agent, ["terminal_type": "claude-code"], source: .declare)
        XCTAssertEqual(revision(), described, "keys the row does not show")

        try write(agent, ["description": "Verifying cancellation"])
        let edited = revision()
        XCTAssertNotEqual(edited, described, "new text moves it")

        try write(agent, ["title": "Retry Audit"])
        let titled = revision()
        XCTAssertNotEqual(titled, edited, "an agent's title moves it")

        try write(shell, ["terminal_type": "shell"], source: .heuristic)
        for title in ["~", "make test", "vim notes.md", "~"] {
            try write(shell, ["title": title], source: .osc)
        }
        try write(UUID(), ["title": "htop"], source: .osc)
        XCTAssertEqual(revision(), titled, "a title no card row shows moves nothing")

        _ = try store.clearMetadata(workspaceId: ws, surfaceId: agent, keys: ["description"], source: .explicit)
        let cleared = revision()
        XCTAssertNotEqual(cleared, titled, "a cleared description moves it")
        XCTAssertEqual(store.cardContextRevision(workspaceId: other), 0, "another workspace keeps its own")

        // The app closes a workspace by pruning every panel (teardownAllPanels).
        store.pruneWorkspace(workspaceId: ws, validSurfaceIds: [])
        XCTAssertEqual(revision(), 0, "a closed workspace leaves no entry")
        try write(agent, ["description": "Reopened"])
        XCTAssertGreaterThan(revision(), cleared, "a later revision never repeats one a reader may hold")
    }
}
