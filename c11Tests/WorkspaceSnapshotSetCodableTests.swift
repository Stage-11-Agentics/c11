import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Codable round-trip tests for `WorkspaceSnapshotSetFile` (the
/// `c11 snapshot --all` manifest envelope) and
/// `WorkspaceSnapshotSetIndex` (the listing row). Pure value tests; no
/// AppKit, no filesystem.
///
/// Per `CLAUDE.md`, never run locally — CI only.
final class WorkspaceSnapshotSetCodableTests: XCTestCase {

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(workspaceSnapshotDateFormatter.string(from: date))
        }
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            guard let date = workspaceSnapshotDateFormatter.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date '\(raw)'")
            }
            return date
        }
        return try decoder.decode(type, from: data)
    }

    func testSnapshotSetFileRoundTrips() throws {
        let set = WorkspaceSnapshotSetFile(
            version: 1,
            setId: "01KQQ9W40HVBQD4X49P6N24DPR",
            createdAt: workspaceSnapshotDateFormatter.date(from: "2026-05-03T16:15:38.000Z")!,
            c11Version: "0.44.1+95",
            selectedWorkspaceIndex: 1,
            snapshots: [
                .init(workspaceRef: "workspace:1",
                      snapshotId: "01KQQ9W40GMMNN40E2H8QKKNKD",
                      order: 0),
                .init(workspaceRef: "workspace:2",
                      snapshotId: "01KQQ9W40HFXDFFJ6KYT399YHP",
                      order: 1,
                      selected: true)
            ]
        )
        let data = try encode(set)
        let decoded = try decode(WorkspaceSnapshotSetFile.self, from: data)
        XCTAssertEqual(decoded, set)
    }

    func testSnapshotSetFileWireUsesSnakeCaseKeys() throws {
        let set = WorkspaceSnapshotSetFile(
            version: 1,
            setId: "01KQTEST00000000000000000Z",
            createdAt: Date(timeIntervalSince1970: 1_745_000_000),
            c11Version: "0.44.1+95",
            selectedWorkspaceIndex: 0,
            snapshots: [.init(workspaceRef: "workspace:1", snapshotId: "01KQA000000000000000000000", order: 0, selected: true)]
        )
        let data = try encode(set)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"set_id\""), "manifest uses snake_case set_id on the wire")
        XCTAssertTrue(json.contains("\"created_at\""), "manifest uses snake_case created_at on the wire")
        XCTAssertTrue(json.contains("\"c11_version\""), "manifest uses snake_case c11_version on the wire")
        XCTAssertTrue(json.contains("\"selected_workspace_index\""))
        XCTAssertTrue(json.contains("\"workspace_ref\""))
        XCTAssertTrue(json.contains("\"snapshot_id\""))
    }

    func testSnapshotSetEntryOmitsSelectedWhenFalse() throws {
        let entry = WorkspaceSnapshotSetFile.Entry(
            workspaceRef: "workspace:3",
            snapshotId: "01KQA000000000000000000000",
            order: 0,
            selected: false
        )
        let data = try encode(entry)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // `selected: false` is the common case; keep the wire minimal.
        XCTAssertFalse(json.contains("\"selected\""), "selected:false omitted on the wire")
        // Decoding a manifest entry without `selected` defaults to false.
        let decoded = try decode(WorkspaceSnapshotSetFile.Entry.self, from: data)
        XCTAssertFalse(decoded.selected)
    }

    func testSnapshotSetIndexRoundTrips() throws {
        let index = WorkspaceSnapshotSetIndex(
            setId: "01KQTESTSETIDXXXXXXXXXXXXXX",
            path: "/Users/op/.c11-snapshots/sets/01KQ.json",
            createdAt: workspaceSnapshotDateFormatter.date(from: "2026-05-03T17:00:00.500Z")!,
            snapshotCount: 3,
            c11Version: "0.44.1+95"
        )
        let data = try encode(index)
        let decoded = try decode(WorkspaceSnapshotSetIndex.self, from: data)
        XCTAssertEqual(decoded, index)
    }
}
