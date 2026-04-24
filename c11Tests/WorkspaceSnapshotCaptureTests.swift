import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Seam-level tests for the Phase 1 snapshot capture + store boundaries.
/// These tests do not touch AppKit: they exercise the `WorkspaceSnapshotSource`
/// protocol via `FakeWorkspaceSnapshotSource`, the filesystem via
/// `WorkspaceSnapshotStore` with a temp `directoryOverride:` init, and
/// the converter's envelope-to-plan boundary.
///
/// The end-to-end path (live TabManager + real walker) lives in the
/// acceptance tests, which run only in CI per `CLAUDE.md`.
@MainActor
final class WorkspaceSnapshotCaptureTests: XCTestCase {

    // MARK: - Store round-trip

    func testStoreWriteThenReadPreservesEnvelope() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceSnapshotStore(
            currentDirectory: tmp,
            legacyDirectory: tmp.appendingPathComponent("legacy-never-exists"),
            fileManager: .default
        )
        let envelope = sampleEnvelope(id: "01KQ0TESTROUNDTRIP0000000")
        let path = try store.write(envelope)
        XCTAssertTrue(path.path.hasSuffix("\(envelope.snapshotId).json"))
        let read = try store.read(from: path)
        XCTAssertEqual(read, envelope)
    }

    func testStoreReadByIdPrefersCurrentOverLegacy() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let current = tmp.appendingPathComponent("current", isDirectory: true)
        let legacy = tmp.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let store = WorkspaceSnapshotStore(
            currentDirectory: current,
            legacyDirectory: legacy,
            fileManager: .default
        )
        let id = "01KQ0LEGACYVSCURRENT0000"
        let currentEnvelope = sampleEnvelope(id: id, title: "current")
        let legacyEnvelope = sampleEnvelope(id: id, title: "legacy")
        _ = try store.write(currentEnvelope)
        let legacyStore = WorkspaceSnapshotStore(
            currentDirectory: legacy,
            legacyDirectory: tmp.appendingPathComponent("nowhere"),
            fileManager: .default
        )
        _ = try legacyStore.write(legacyEnvelope)
        let resolved = try store.read(byId: id)
        XCTAssertEqual(resolved.plan.workspace.title, "current")
    }

    func testStoreReadByIdFallsBackToLegacyDirectory() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let current = tmp.appendingPathComponent("current", isDirectory: true)
        let legacy = tmp.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let store = WorkspaceSnapshotStore(
            currentDirectory: current,
            legacyDirectory: legacy,
            fileManager: .default
        )
        let id = "01KQ0LEGACYFALLBACK00000"
        let legacyEnvelope = sampleEnvelope(id: id, title: "legacy-source")
        let legacyURL = legacy.appendingPathComponent("\(id).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacyEnvelope).write(to: legacyURL, options: .atomic)
        let resolved = try store.read(byId: id)
        XCTAssertEqual(resolved.plan.workspace.title, "legacy-source")
    }

    func testStoreReadByIdErrorsWhenMissingInBothDirs() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceSnapshotStore(
            currentDirectory: tmp.appendingPathComponent("c"),
            legacyDirectory: tmp.appendingPathComponent("l"),
            fileManager: .default
        )
        XCTAssertThrowsError(try store.read(byId: "01KQ0DOESNOTEXIST0000000")) { error in
            guard let storeError = error as? WorkspaceSnapshotStore.StoreError,
                  case .notFound = storeError else {
                XCTFail("expected StoreError.notFound; got \(error)")
                return
            }
            XCTAssertEqual(storeError.code, "snapshot_not_found")
        }
    }

    func testStoreListMergesCurrentAndLegacyAndTagsSource() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let current = tmp.appendingPathComponent("current", isDirectory: true)
        let legacy = tmp.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

        let store = WorkspaceSnapshotStore(
            currentDirectory: current,
            legacyDirectory: legacy,
            fileManager: .default
        )
        let legacyStore = WorkspaceSnapshotStore(
            currentDirectory: legacy,
            legacyDirectory: tmp.appendingPathComponent("nope"),
            fileManager: .default
        )
        let a = sampleEnvelope(
            id: "01KQ0AA0000000000000000A",
            title: "alpha",
            createdAt: Date(timeIntervalSince1970: 1_745_000_000)
        )
        let b = sampleEnvelope(
            id: "01KQ0BB0000000000000000B",
            title: "beta",
            createdAt: Date(timeIntervalSince1970: 1_745_001_000)
        )
        _ = try store.write(a)
        _ = try legacyStore.write(b)
        let list = try store.list()
        XCTAssertEqual(list.count, 2)
        // Sort is newest-first.
        XCTAssertEqual(list.first?.snapshotId, b.snapshotId)
        let aEntry = try XCTUnwrap(list.first { $0.snapshotId == a.snapshotId })
        let bEntry = try XCTUnwrap(list.first { $0.snapshotId == b.snapshotId })
        XCTAssertEqual(aEntry.source, .current)
        XCTAssertEqual(bEntry.source, .legacy)
        XCTAssertEqual(aEntry.workspaceTitle, "alpha")
        XCTAssertEqual(bEntry.workspaceTitle, "beta")
    }

    /// I8 (was: testStoreListSkipsMalformedJSON). Before I8, malformed JSON
    /// was silently dropped. After I8, it surfaces as an unreadable row
    /// with a best-effort id (filename stem), preserving the healthy entry
    /// at the top of the newest-first sort.
    func testStoreListSurfacesMalformedJSONAsUnreadableRow() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let garbageId = "01KQ0GARBAGE000000000000"
        let garbage = tmp.appendingPathComponent("\(garbageId).json")
        try Data("not json".utf8).write(to: garbage, options: .atomic)
        let valid = sampleEnvelope(id: "01KQ0VALIDLIST0000000000")
        let store = WorkspaceSnapshotStore(
            currentDirectory: tmp,
            legacyDirectory: tmp.appendingPathComponent("nowhere"),
            fileManager: .default
        )
        _ = try store.write(valid)
        let list = try store.list()
        XCTAssertEqual(list.count, 2, "both healthy and unreadable rows appear")
        let valids = list.filter { $0.readability == .ok }
        let unreadables = list.filter {
            if case .unreadable = $0.readability { return true } else { return false }
        }
        XCTAssertEqual(valids.count, 1)
        XCTAssertEqual(valids.first?.snapshotId, valid.snapshotId)
        XCTAssertEqual(unreadables.count, 1)
        let unreadable = try XCTUnwrap(unreadables.first)
        XCTAssertEqual(unreadable.snapshotId, garbageId, "unreadable row id is filename stem")
        XCTAssertEqual(unreadable.path, garbage.path)
        XCTAssertEqual(unreadable.surfaceCount, 0)
        XCTAssertEqual(unreadable.createdAt, .distantPast, "unreadable rows sort to the bottom")
        if case .unreadable(let reason) = unreadable.readability {
            XCTAssertFalse(reason.isEmpty, "reason is best-effort but must be populated")
            XCTAssertLessThanOrEqual(reason.count, 160, "reason is truncated to 160 chars")
        } else {
            XCTFail("expected .unreadable variant")
        }
    }

    /// Sort invariant: healthy rows come first (newest createdAt),
    /// unreadable rows come last (createdAt = .distantPast).
    func testStoreListSortsHealthyBeforeUnreadable() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let garbage = tmp.appendingPathComponent("01KQ0GARBAGE00SORT000000.json")
        try Data("{\"not\": \"a snapshot\"}".utf8).write(to: garbage, options: .atomic)
        let valid = sampleEnvelope(
            id: "01KQ0SORTVALID0000000000",
            createdAt: Date(timeIntervalSince1970: 1_745_000_000)
        )
        let store = WorkspaceSnapshotStore(
            currentDirectory: tmp,
            legacyDirectory: tmp.appendingPathComponent("nowhere"),
            fileManager: .default
        )
        _ = try store.write(valid)
        let list = try store.list()
        XCTAssertEqual(list.first?.readability, .ok, "healthy row first")
        XCTAssertEqual(list.count, 2)
    }

    /// Readability round-trips through Codable.
    func testReadabilityRoundTripsThroughCodable() throws {
        let ok = WorkspaceSnapshotIndex(
            snapshotId: "01KQ0RTOK00000000000000",
            path: "/tmp/ok.json",
            createdAt: Date(timeIntervalSince1970: 1_745_000_000),
            workspaceTitle: "ok",
            surfaceCount: 1,
            origin: .manual,
            source: .current,
            readability: .ok
        )
        let bad = WorkspaceSnapshotIndex(
            snapshotId: "01KQ0RTBAD0000000000000",
            path: "/tmp/bad.json",
            createdAt: .distantPast,
            workspaceTitle: nil,
            surfaceCount: 0,
            origin: .manual,
            source: .current,
            readability: .unreadable("parse error: truncated")
        )
        for entry in [ok, bad] {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entry)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(WorkspaceSnapshotIndex.self, from: data)
            XCTAssertEqual(decoded.readability, entry.readability)
            XCTAssertEqual(decoded.snapshotId, entry.snapshotId)
        }
    }

    // MARK: - P1: header-only summary for `snapshot.list`

    /// New-file path: when the envelope carries `surface_count` explicitly
    /// (as written by `LiveWorkspaceSnapshotSource.capture` after P1), the
    /// list path surfaces that count verbatim — no full-plan decode.
    func testStoreListReadsExplicitSurfaceCountFromEnvelope() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceSnapshotStore(
            currentDirectory: tmp,
            legacyDirectory: tmp.appendingPathComponent("nowhere"),
            fileManager: .default
        )
        var envelope = sampleEnvelope(id: "01KQ0SURFACECOUNT0000000")
        // Fabricate a disagreement so we can prove the list path reads the
        // explicit envelope count, not the embedded plan's count. In the
        // real world the two always agree — capture writes both — but if
        // somebody hand-edits the file, the envelope field wins.
        envelope.surfaceCount = 7
        _ = try store.write(envelope)
        let list = try store.list()
        let entry = try XCTUnwrap(list.first)
        XCTAssertEqual(entry.surfaceCount, 7)
    }

    /// Legacy-file path: an envelope written before P1 landed omits
    /// `surface_count`. The list path falls back to the embedded plan's
    /// `surfaces.count`.
    func testStoreListFallsBackToPlanSurfacesCountWhenEnvelopeLacksKey() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceSnapshotStore(
            currentDirectory: tmp,
            legacyDirectory: tmp.appendingPathComponent("nowhere"),
            fileManager: .default
        )
        // Craft a legacy-shaped JSON by hand — no surface_count key, two
        // surfaces in the embedded plan.
        let id = "01KQ0LEGACYSURFACECOUNT0"
        let legacyJSON = """
        {
          "version": 1,
          "snapshot_id": "\(id)",
          "created_at": "2026-04-24T18:00:00.000Z",
          "c11_version": "0.01.0+1",
          "origin": "manual",
          "plan": {
            "version": 1,
            "workspace": { "title": "legacy shape" },
            "layout": {
              "type": "pane",
              "pane": { "surfaceIds": ["a", "b"] }
            },
            "surfaces": [
              { "id": "a", "kind": "terminal" },
              { "id": "b", "kind": "terminal" }
            ]
          }
        }
        """
        let url = tmp.appendingPathComponent("\(id).json")
        try Data(legacyJSON.utf8).write(to: url, options: .atomic)
        let list = try store.list()
        let entry = try XCTUnwrap(list.first { $0.snapshotId == id })
        XCTAssertEqual(entry.surfaceCount, 2, "fallback to plan.surfaces.count when envelope lacks surface_count")
        XCTAssertEqual(entry.workspaceTitle, "legacy shape")
    }

    // MARK: - Capture seam (fake source)

    func testFakeSourceReturnsCannedEnvelope() {
        let envelope = sampleEnvelope(id: "01KQ0FAKECAPTURE00000000")
        let fake = FakeWorkspaceSnapshotSource(canned: envelope)
        let captured = fake.capture(
            workspaceId: UUID(),
            origin: .manual,
            clock: { Date(timeIntervalSince1970: 1_745_000_000) }
        )
        XCTAssertEqual(captured, envelope)
    }

    func testFakeSourceCanReturnNil() {
        let fake = FakeWorkspaceSnapshotSource(canned: nil)
        XCTAssertNil(fake.capture(
            workspaceId: UUID(),
            origin: .manual,
            clock: { Date() }
        ))
    }

    // MARK: - Capture → Write → Read → Convert loop

    func testCaptureWriteReadConvertRoundTrip() throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceSnapshotStore(
            currentDirectory: tmp,
            legacyDirectory: tmp.appendingPathComponent("nowhere"),
            fileManager: .default
        )
        let envelope = sampleEnvelope(id: "01KQ0FULLROUNDTRIP00000")
        let fake = FakeWorkspaceSnapshotSource(canned: envelope)
        let captured = try XCTUnwrap(fake.capture(
            workspaceId: UUID(),
            origin: .manual,
            clock: { Date(timeIntervalSince1970: 1_745_000_000) }
        ))
        let path = try store.write(captured)
        let readBack = try store.read(from: path)
        let planResult = WorkspaceSnapshotConverter.applyPlan(from: readBack)
        guard case .success(let plan) = planResult else {
            XCTFail("converter rejected round-tripped envelope: \(planResult)")
            return
        }
        XCTAssertEqual(plan, captured.plan)
    }

    // MARK: - ULID-shape sanity

    func testSnapshotIDGenerateProducesCrockfordBase32Stem() {
        let id = WorkspaceSnapshotID.generate(
            now: Date(timeIntervalSince1970: 1_745_000_000),
            random: { 0x0123_4567_89AB_CDEF }
        )
        XCTAssertEqual(id.count, 26, "ULID-shaped ids are 26 chars")
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        for scalar in id.unicodeScalars {
            XCTAssertTrue(allowed.contains(scalar), "char '\(scalar)' outside Crockford base32")
        }
    }

    /// I1 regression guard: the earlier accumulator was 64 bits but the
    /// loop shifted out 80 bits, forcing a deterministic `'0'` run near
    /// the suffix of the random portion. Verify that position 10 (first
    /// char of the random portion, LSB of the upper half) varies across
    /// many RNG draws — with a proper 40-bit upper accumulator it should
    /// hit all 32 alphabet characters given enough samples.
    func testSnapshotIDRandomPortionUsesAllBits() {
        var rng = SystemRandomNumberGenerator()
        var seen: Set<Character> = []
        let samples = 10_000
        for _ in 0..<samples {
            let id = WorkspaceSnapshotID.generate(
                now: Date(timeIntervalSince1970: 1_745_000_000),
                random: { rng.next() }
            )
            // Position 10 = first char after the 10-char time prefix,
            // i.e. MSB of the upper-40 random half. With the old bug it
            // was drawn from bits that included zeros forced by the
            // accumulator overflow.
            let chars = Array(id)
            seen.insert(chars[10])
        }
        XCTAssertGreaterThan(
            seen.count,
            24,
            "position 10 should sample most of the 32 alphabet characters across \(samples) draws; saw \(seen.sorted())"
        )
    }

    /// Time prefix of a ULID-shaped id must decode back to the millisecond
    /// value of the injected clock. Capture reads the clock once and passes
    /// that value to both `WorkspaceSnapshotID.generate(now:)` and the
    /// envelope's `createdAt`, so verifying the decode invariant lets us
    /// rely on "ULID prefix millis == createdAt millis" byte-for-byte.
    func testSnapshotIDTimePrefixDecodesToInjectedClockMillis() {
        let instants: [TimeInterval] = [
            1_745_000_000.000,
            1_745_000_000.999,
            1_600_000_123.456,
            0.000
        ]
        for interval in instants {
            let now = Date(timeIntervalSince1970: interval)
            let id = WorkspaceSnapshotID.generate(now: now)
            let prefix = String(id.prefix(10))
            let decoded = Self.decodeCrockfordBase32(prefix)
            let expected = UInt64(now.timeIntervalSince1970 * 1000)
            XCTAssertEqual(
                decoded,
                expected,
                "ULID time prefix '\(prefix)' must decode to \(expected) ms"
            )
        }
    }

    /// Crockford base32 decoder for the 10-char time prefix. Kept inside the
    /// test class so it stays scoped to the invariant it is verifying.
    private static func decodeCrockfordBase32(_ input: String) -> UInt64 {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var result: UInt64 = 0
        for char in input {
            guard let idx = alphabet.firstIndex(of: char) else { return 0 }
            result = (result << 5) | UInt64(idx)
        }
        return result
    }

    /// Historical bug: position 12 of the id was always `'0'` because
    /// the accumulator ran out of bits. Positive lock: after enough
    /// samples, position 12 must see at least 16 distinct characters.
    func testSnapshotIDRandomPortionNoDeterministicZeroAtPosition12() {
        var rng = SystemRandomNumberGenerator()
        var seenAtPos12: Set<Character> = []
        let samples = 10_000
        for _ in 0..<samples {
            let id = WorkspaceSnapshotID.generate(
                now: Date(timeIntervalSince1970: 1_745_000_000),
                random: { rng.next() }
            )
            seenAtPos12.insert(Array(id)[12])
        }
        XCTAssertGreaterThan(
            seenAtPos12.count,
            16,
            "position 12 should not be deterministic; saw \(seenAtPos12.sorted())"
        )
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleEnvelope(
        id: String,
        title: String = "Capture Test",
        createdAt: Date = Date(timeIntervalSince1970: 1_745_000_000)
    ) -> WorkspaceSnapshotFile {
        WorkspaceSnapshotFile(
            version: 1,
            snapshotId: id,
            createdAt: createdAt,
            c11Version: "0.01.0+1",
            origin: .manual,
            plan: WorkspaceApplyPlan(
                version: 1,
                workspace: WorkspaceSpec(title: title),
                layout: .pane(.init(surfaceIds: ["a"])),
                surfaces: [SurfaceSpec(id: "a", kind: .terminal, title: "shell")]
            )
        )
    }
}
