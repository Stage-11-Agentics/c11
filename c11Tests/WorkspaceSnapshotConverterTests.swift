import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure Codable + converter tests for `WorkspaceSnapshotFile` →
/// `WorkspaceApplyPlan`. Fixture-driven so the on-disk JSON shape is
/// double-checked alongside the Swift translation; Phase 2 (Blueprints) and
/// Phase 3 (`--all`) both serialise through the same envelope and benefit
/// from that rigor.
///
/// No AppKit, no stores. Per `CLAUDE.md`, never run locally — CI only.
final class WorkspaceSnapshotConverterTests: XCTestCase {

    // MARK: - Fixture location

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("workspace-snapshots", isDirectory: true)
    }

    private func loadSnapshot(_ name: String) throws -> WorkspaceSnapshotFile {
        let url = fixturesDir.appendingPathComponent("\(name).json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkspaceSnapshotFile.self, from: data)
    }

    // MARK: - Codable round-trip

    func testEnvelopeRoundTripsThroughJSON() throws {
        let original = WorkspaceSnapshotFile(
            version: 1,
            snapshotId: "01KQ0TEST000000000000000AB",
            createdAt: Date(timeIntervalSince1970: 1_745_000_000),
            c11Version: "0.01.123+42",
            origin: .manual,
            plan: minimalPlan()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkspaceSnapshotFile.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// I9 regression guard: store writes + reads must preserve fractional
    /// seconds on `createdAt`. The default `.iso8601` strategy truncates
    /// to second precision, which breaks round-trip equality for a
    /// `Date()` whose timeIntervalSince1970 has millisecond resolution.
    func testStoreWriteReadPreservesFractionalSeconds() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-snapshot-i9-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = WorkspaceSnapshotStore(
            currentDirectory: tmp,
            legacyDirectory: tmp.appendingPathComponent("legacy"),
            fileManager: .default
        )
        // A Date with millisecond precision the old `.iso8601` strategy
        // would silently truncate to the nearest second.
        let millis = Date(timeIntervalSince1970: 1_745_000_000.123)
        let original = WorkspaceSnapshotFile(
            version: 1,
            snapshotId: "01KQ0I9FRACTIONALROUNDTRIP",
            createdAt: millis,
            c11Version: "i9+0",
            origin: .manual,
            plan: minimalPlan()
        )
        let writtenURL = try store.write(original)
        let readBack = try store.read(from: writtenURL)
        XCTAssertEqual(
            readBack.createdAt.timeIntervalSince1970,
            original.createdAt.timeIntervalSince1970,
            accuracy: 0.0005,
            "fractional seconds must survive the write/read round-trip"
        )
        // Raw JSON payload carries the fractional token.
        let raw = try String(contentsOf: writtenURL, encoding: .utf8)
        XCTAssertTrue(
            raw.contains(".123") || raw.contains(".124") || raw.contains(".122"),
            "serialised JSON should contain the fractional seconds segment; got:\n\(raw)"
        )
    }

    func testEnvelopeUsesSnakeCaseOnTheWire() throws {
        let value = WorkspaceSnapshotFile(
            version: 1,
            snapshotId: "01KQ0WIRECASEXXXXXXXXXXXXX",
            createdAt: Date(timeIntervalSince1970: 1_745_000_000),
            c11Version: "0.01.123+42",
            origin: .autoRestart,
            plan: minimalPlan()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"snapshot_id\":"), "wire uses snake_case for snapshot_id")
        XCTAssertTrue(json.contains("\"created_at\":"), "wire uses snake_case for created_at")
        XCTAssertTrue(json.contains("\"c11_version\":"), "wire uses snake_case for c11_version")
        XCTAssertTrue(json.contains("\"auto-restart\""), "origin enum serializes with hyphen form")
    }

    // MARK: - Fixture matrix

    func testMinimalSingleTerminalFixtureConverts() throws {
        let snapshot = try loadSnapshot("minimal-single-terminal")
        let result = WorkspaceSnapshotConverter.applyPlan(from: snapshot)
        let plan = try unwrap(result)
        XCTAssertEqual(plan.version, 1)
        XCTAssertEqual(plan.surfaces.count, 1)
        XCTAssertEqual(plan.surfaces[0].kind, .terminal)
        XCTAssertNil(plan.surfaces[0].command, "minimal fixture has no command")
    }

    func testClaudeCodeWithSessionFixturePreservesMetadataButNotCommand() throws {
        let snapshot = try loadSnapshot("claude-code-with-session")
        let plan = try unwrap(WorkspaceSnapshotConverter.applyPlan(from: snapshot))
        XCTAssertEqual(plan.surfaces.count, 1)
        let surface = plan.surfaces[0]
        XCTAssertEqual(surface.kind, .terminal)
        XCTAssertNil(
            surface.command,
            "converter never synthesizes a command; that's the executor's job"
        )
        XCTAssertEqual(
            surface.metadata?[SurfaceMetadataKeyName.terminalType],
            .string(SurfaceMetadataKeyName.terminalTypeClaudeCode),
            "terminal_type metadata round-trips through the converter"
        )
        XCTAssertEqual(
            surface.metadata?[SurfaceMetadataKeyName.claudeSessionId],
            .string("abc12345-ef67-890a-bcde-f0123456789a"),
            "claude.session_id metadata round-trips through the converter"
        )
    }

    func testMailboxRoundTripFixturePreservesPaneMetadataByteForByte() throws {
        let snapshot = try loadSnapshot("mailbox-roundtrip")
        let plan = try unwrap(WorkspaceSnapshotConverter.applyPlan(from: snapshot))
        let surface = try XCTUnwrap(plan.surfaces.first)
        let pane = try XCTUnwrap(surface.paneMetadata)
        XCTAssertEqual(pane["mailbox.delivery"], .string("stdin,watch"))
        XCTAssertEqual(pane["mailbox.subscribe"], .string("build.*,deploy.green"))
        XCTAssertEqual(pane["mailbox.retention_days"], .string("7"))
        XCTAssertEqual(pane.count, 3, "no extra mailbox.* keys introduced by the converter")
    }

    func testMixedSurfacesFixturePreservesTreeShape() throws {
        let snapshot = try loadSnapshot("mixed-surfaces")
        let plan = try unwrap(WorkspaceSnapshotConverter.applyPlan(from: snapshot))
        // Surfaces are addressed by stable plan-local ids.
        let ids = Set(plan.surfaces.map { $0.id })
        XCTAssertEqual(ids, ["term1", "md1", "web1"])
        // Layout is a horizontal split at the root.
        guard case .split(let split) = plan.layout else {
            XCTFail("mixed-surfaces fixture is a split at the root")
            return
        }
        XCTAssertEqual(split.orientation, .horizontal)
        XCTAssertEqual(split.dividerPosition, 0.5, accuracy: 0.001)
        guard case .pane(let leftPane) = split.first else {
            XCTFail("left branch should be a pane")
            return
        }
        XCTAssertEqual(leftPane.surfaceIds, ["term1", "md1"])
        guard case .pane(let rightPane) = split.second else {
            XCTFail("right branch should be a pane")
            return
        }
        XCTAssertEqual(rightPane.surfaceIds, ["web1"])
    }

    func testVersionMismatchFixtureFailsWithTypedError() throws {
        let snapshot = try loadSnapshot("version-mismatch")
        let result = WorkspaceSnapshotConverter.applyPlan(from: snapshot)
        guard case .failure(let err) = result else {
            XCTFail("expected .failure; got .success")
            return
        }
        XCTAssertEqual(err, .versionUnsupported(999))
        XCTAssertEqual(err.code, "snapshot_version_unsupported")
    }

    func testPlanVersionMismatchReturnsTypedError() {
        // Construct a synthetic envelope with a bogus plan version. No
        // fixture file because the envelope format has only one version
        // today and we want this failure mode covered orthogonally.
        var plan = minimalPlan()
        plan.version = 42
        let snapshot = WorkspaceSnapshotFile(
            version: 1,
            snapshotId: "01KQ0PLANVERSIONMISMATCH00",
            createdAt: Date(timeIntervalSince1970: 1_745_000_000),
            c11Version: "0.01.0+1",
            origin: .manual,
            plan: plan
        )
        let result = WorkspaceSnapshotConverter.applyPlan(from: snapshot)
        guard case .failure(let err) = result else {
            XCTFail("expected .failure for plan version 42")
            return
        }
        XCTAssertEqual(err, .planVersionUnsupported(42))
        XCTAssertEqual(err.code, "snapshot_plan_version_unsupported")
    }

    // MARK: - Helpers

    private func unwrap<T, E>(_ result: Result<T, E>) throws -> T {
        switch result {
        case .success(let value): return value
        case .failure(let error): throw XCTSkipResult(error: error)
        }
    }

    private func minimalPlan() -> WorkspaceApplyPlan {
        WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(title: "Converter Test"),
            layout: .pane(.init(surfaceIds: ["a"])),
            surfaces: [SurfaceSpec(id: "a", kind: .terminal)]
        )
    }

    /// XCTest helper that turns a converter failure into a thrown error so
    /// the call site stays linear. Not reused elsewhere — declared here to
    /// keep the test file self-contained.
    private struct XCTSkipResult: Error, CustomStringConvertible {
        let error: Any
        var description: String { "converter returned failure: \(error)" }
    }
}
