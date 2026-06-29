import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure tests for `PiScraper` + `PiStrategy` (C11-153 pi exact-session resume).
///
/// Member of the **`c11LogicTests`** target only, so it runs on the safe
/// `c11-logic` scheme. All mocks are declared locally — the host-target
/// `ConversationScraperTests.MockFS` is not reachable from this target
/// (mirrors `ScrapeCapturePipelineTests`).
final class PiConversationTests: XCTestCase {

    // MARK: - Local mocks (logic-target-local; do not borrow host-target helpers)

    final class MockFS: ConversationFilesystem, @unchecked Sendable {
        var home: URL?
        var recursiveEntries: [URL: [ConversationFilesystemEntry]] = [:]
        var directoryEntries: [URL: [ConversationFilesystemEntry]] = [:]
        var existingPaths: Set<String> = []

        var homeDirectory: URL? { home }
        func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }
        func listDirectoryByMtime(_ directory: URL, max: Int) -> [ConversationFilesystemEntry] {
            Array((directoryEntries[directory] ?? [])
                .sorted { $0.mtime > $1.mtime }
                .prefix(max))
        }
        func listSessionsRecursivelyByMtime(
            _ root: URL,
            extensionFilter: String,
            max: Int
        ) -> [ConversationFilesystemEntry] {
            Array((recursiveEntries[root] ?? [])
                .filter { $0.fileName.hasSuffix("." + extensionFilter) }
                .prefix(max))
        }
    }

    private func entry(_ dir: URL, _ name: String, mtime: Date, size: Int64 = 1024) -> ConversationFilesystemEntry {
        ConversationFilesystemEntry(
            url: dir.appendingPathComponent(name), fileName: name, mtime: mtime, size: size
        )
    }

    // A real pi filename shape: `<ISO-ts>_<uuidv7>.jsonl`. The timestamp has
    // no `_`, so the id is the substring after the last `_`.
    private let piUUID = "019f0b02-83b3-7c97-b12c-05946daccc84"
    private let piUUID2 = "019f0b53-537e-75da-a487-10737b50b4e3"
    private func piFileName(ts: String, uuid: String) -> String { "\(ts)_\(uuid).jsonl" }

    /// Build the sessions-root URL exactly as `PiScraper.sessionsRoot()` does
    /// (three `isDirectory: true` appends), so the `MockFS` dictionary key
    /// matches the URL the scraper looks up — URL equality is construction-
    /// sensitive, so a single `".pi/agent/sessions"` component would not match.
    private func sessionsRoot(_ home: String) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    // MARK: - PiScraper

    func testPiScraperExtractsUUIDAfterLastUnderscore() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = sessionsRoot("/Users/test")
        let slug = root.appendingPathComponent("--Users-test-proj--")
        let name = piFileName(ts: "2026-06-27T21-35-42-003Z", uuid: piUUID)
        mock.recursiveEntries[root] = [
            ConversationFilesystemEntry(
                url: slug.appendingPathComponent(name),
                fileName: name,
                mtime: Date(),
                size: 4096
            )
        ]
        let scraper = PiScraper(filesystem: mock)
        let candidates = scraper.candidates()
        XCTAssertEqual(candidates.count, 1)
        // The id is the UUID, NOT the timestamp-prefixed stem.
        XCTAssertEqual(candidates[0].id, piUUID)
    }

    func testPiScraperRecursivelyReturnsTopByMtime() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = sessionsRoot("/Users/test")
        let slugA = root.appendingPathComponent("--Users-test-a--")
        let slugB = root.appendingPathComponent("--Users-test-b--")
        let nameNew = piFileName(ts: "2026-06-27T23-03-58-078Z", uuid: piUUID2)
        let nameOld = piFileName(ts: "2026-06-27T21-35-42-003Z", uuid: piUUID)
        let now = Date()
        mock.recursiveEntries[root] = [
            ConversationFilesystemEntry(
                url: slugB.appendingPathComponent(nameNew),
                fileName: nameNew, mtime: now, size: 2048
            ),
            ConversationFilesystemEntry(
                url: slugA.appendingPathComponent(nameOld),
                fileName: nameOld, mtime: now.addingTimeInterval(-3600), size: 1024
            )
        ]
        let candidates = PiScraper(filesystem: mock).candidates()
        XCTAssertEqual(candidates.map(\.id), [piUUID2, piUUID])
    }

    func testPiScraperRejectsNonUUIDTailAndNoUnderscore() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = sessionsRoot("/Users/test")
        let slug = root.appendingPathComponent("--Users-test-proj--")
        let valid = piFileName(ts: "2026-06-27T21-35-42-003Z", uuid: piUUID)
        mock.recursiveEntries[root] = [
            // valid
            ConversationFilesystemEntry(
                url: slug.appendingPathComponent(valid),
                fileName: valid, mtime: Date(), size: 1024
            ),
            // tail after last `_` is not a UUID
            ConversationFilesystemEntry(
                url: slug.appendingPathComponent("2026-06-27T21-35-42-003Z_not-a-uuid.jsonl"),
                fileName: "2026-06-27T21-35-42-003Z_not-a-uuid.jsonl",
                mtime: Date(), size: 50
            ),
            // no underscore at all (whole stem is not a UUID)
            ConversationFilesystemEntry(
                url: slug.appendingPathComponent("plainname.jsonl"),
                fileName: "plainname.jsonl", mtime: Date(), size: 50
            )
        ]
        let candidates = PiScraper(filesystem: mock).candidates()
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].id, piUUID)
    }

    func testPiScraperEmptyWhenDirMissing() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        // No recursiveEntries keyed for the sessions root.
        XCTAssertTrue(PiScraper(filesystem: mock).candidates().isEmpty)
    }

    /// Slug encoding mirrors pi exactly: strip leading `/`, map `/ \ :` → `-`,
    /// wrap in `--…--`. Dots are preserved (pi does not map `.`).
    func testPiSessionSlugMatchesPiEncoding() {
        XCTAssertEqual(
            PiScraper.sessionSlug(forCwd: "/Users/atin/Projects/Gregorovich"),
            "--Users-atin-Projects-Gregorovich--"
        )
        XCTAssertEqual(
            PiScraper.sessionSlug(forCwd: "/work/my.proj"),
            "--work-my.proj--"  // dot preserved
        )
    }

    /// When a cwd is known, the scraper scopes to that cwd's slug directory and
    /// stamps the surface cwd onto the candidate.
    func testPiScraperScopesToCwdSlugDirectory() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = sessionsRoot("/Users/test")
        let cwd = "/work/proj"
        let slugDir = root.appendingPathComponent(PiScraper.sessionSlug(forCwd: cwd), isDirectory: true)
        let name = piFileName(ts: "2026-06-27T21-35-42-003Z", uuid: piUUID)
        mock.directoryEntries[slugDir] = [entry(slugDir, name, mtime: Date())]
        let candidates = PiScraper(filesystem: mock).candidates(cwd: cwd)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].id, piUUID)
        XCTAssertEqual(candidates[0].cwd, cwd)
    }

    /// The narrowing is real: a session in a DIFFERENT cwd's slug dir is not
    /// returned when scraping for this cwd — even if it is newer. This is what
    /// lets exact resume fire on a machine with many pi sessions (pi has no
    /// wrapper-claim floor to narrow by, unlike codex).
    func testPiScraperDoesNotLeakSessionsFromOtherCwds() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = sessionsRoot("/Users/test")
        let mineDir = root.appendingPathComponent(PiScraper.sessionSlug(forCwd: "/work/mine"), isDirectory: true)
        let otherDir = root.appendingPathComponent(PiScraper.sessionSlug(forCwd: "/work/other"), isDirectory: true)
        let now = Date()
        mock.directoryEntries[mineDir] = [
            entry(mineDir, piFileName(ts: "2026-06-27T21-35-42-003Z", uuid: piUUID), mtime: now.addingTimeInterval(-3600))
        ]
        // Newer session, but in a different cwd's dir — must be invisible.
        mock.directoryEntries[otherDir] = [
            entry(otherDir, piFileName(ts: "2026-06-27T23-03-58-078Z", uuid: piUUID2), mtime: now)
        ]
        let candidates = PiScraper(filesystem: mock).candidates(cwd: "/work/mine")
        XCTAssertEqual(candidates.map(\.id), [piUUID], "only the matching cwd's session is returned")
    }

    func testPiScraperEmptyWhenCwdSlugDirMissing() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        // No directoryEntries keyed for the cwd's slug dir.
        XCTAssertTrue(PiScraper(filesystem: mock).candidates(cwd: "/work/proj").isEmpty)
    }

    // MARK: - PiStrategy / pipeline end-to-end

    private func candidate(_ id: String, mtime: Date, cwd: String? = nil) -> ScrapeCandidate {
        ScrapeCandidate(
            id: id,
            filePath: "/Users/test/.pi/agent/sessions/--slug--/2026-06-27T21-35-42-003Z_\(id).jsonl",
            mtime: mtime, size: 1024, cwd: cwd
        )
    }

    /// The gate: a single pi candidate resolves through the pipeline into a
    /// scrape-derived, alive ref that resumes via `pi --session '<uuid>'`.
    func testPiSingleCandidateResumesExactSession() {
        let surfaceId = UUID().uuidString
        let now = Date()
        let scrapers = ConversationScraperRegistry(scrapers: [
            MockScraper(kind: "pi", preset: [candidate(piUUID, mtime: now)])
        ])
        let pipeline = ScrapeCapturePipeline(scrapers: scrapers, strategies: .v1)
        let contexts = [ScrapeCaptureContext(surfaceId: surfaceId, kind: "pi", cwd: "/work/proj")]

        let captured = pipeline.captureRefs(contexts: contexts, existing: [:])
        XCTAssertEqual(captured.count, 1)
        let ref = captured[0].ref
        XCTAssertEqual(captured[0].surfaceId, surfaceId)
        XCTAssertEqual(ref.kind, "pi")
        XCTAssertEqual(ref.id, piUUID)
        XCTAssertEqual(ref.capturedVia, .scrape)
        XCTAssertEqual(ref.state, .alive)

        let action = PiStrategy().resume(ref: ref)
        guard case let .typeCommand(text, submit) = action else {
            return XCTFail("expected .typeCommand, got \(action)")
        }
        XCTAssertEqual(text, "pi --session '\(piUUID)'")
        XCTAssertTrue(submit)
    }

    /// Two candidates for the same surface → `.unknown`, and `resume` skips
    /// so neither pane steals the other's session.
    func testPiAmbiguousCandidatesYieldUnknownAndSkip() {
        let surfaceId = UUID().uuidString
        let now = Date()
        let scrapers = ConversationScraperRegistry(scrapers: [
            MockScraper(kind: "pi", preset: [
                candidate(piUUID, mtime: now),
                candidate(piUUID2, mtime: now.addingTimeInterval(-30))
            ])
        ])
        let pipeline = ScrapeCapturePipeline(scrapers: scrapers, strategies: .v1)
        let contexts = [ScrapeCaptureContext(surfaceId: surfaceId, kind: "pi", cwd: "/work/proj")]

        let captured = pipeline.captureRefs(contexts: contexts, existing: [:])
        XCTAssertEqual(captured.count, 1)
        let ref = captured[0].ref
        XCTAssertEqual(ref.state, .unknown)
        XCTAssertEqual(ref.id, piUUID, "newest-first chosen for the diagnostic id")

        if case .skip = PiStrategy().resume(ref: ref) {
            // expected
        } else {
            XCTFail("ambiguous ref must skip")
        }
    }

    /// pi has no wrapper-claim rail in production, so this state is only
    /// reachable via future wiring — construct the placeholder directly and
    /// assert resume skips it.
    func testPiPlaceholderRefSkips() {
        let ref = ConversationRef(
            kind: "pi",
            id: piUUID,
            placeholder: true,
            capturedVia: .wrapperClaim,
            state: .alive
        )
        if case let .skip(reason) = PiStrategy().resume(ref: ref) {
            XCTAssertTrue(reason.contains("placeholder"))
        } else {
            XCTFail("placeholder ref must skip")
        }
    }

    func testPiStrategyValidatesUUIDGrammar() {
        let s = PiStrategy()
        XCTAssertTrue(s.isValidId(piUUID))
        XCTAssertFalse(s.isValidId("not-a-uuid"))
        XCTAssertFalse(s.isValidId(""))
    }

    // MARK: - Local stub scraper

    /// Returns preset candidates regardless of cwd, stamping the passed cwd
    /// onto each (mirrors the real scrapers). Local to this target.
    struct MockScraper: ConversationScraper {
        let kind: String
        let preset: [ScrapeCandidate]
        func candidates(cwd: String?) -> [ScrapeCandidate] {
            preset.map {
                ScrapeCandidate(id: $0.id, filePath: $0.filePath, mtime: $0.mtime, size: $0.size, cwd: cwd ?? $0.cwd)
            }
        }
    }
}
