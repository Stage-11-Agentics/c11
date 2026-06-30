import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure tests for `OmpScraper` and `OmpStrategy` (oh-my-pi exact-session
/// resume) against a mock filesystem. Lives in the host-free `c11LogicTests`
/// target so it runs under the `c11-logic` scheme without launching a c11
/// DEV.app. Mirrors the `MockFS` shape used by `ConversationScraperTests`.
final class OmpConversationTests: XCTestCase {

    // MARK: - Mock filesystem

    final class MockFS: ConversationFilesystem, @unchecked Sendable {
        var home: URL?
        var directoryEntries: [URL: [ConversationFilesystemEntry]] = [:]
        var recursiveEntries: [URL: [ConversationFilesystemEntry]] = [:]
        var existingPaths: Set<String> = []

        var homeDirectory: URL? { home }

        func fileExists(atPath path: String) -> Bool {
            existingPaths.contains(path)
        }

        func listDirectoryByMtime(_ directory: URL, max: Int) -> [ConversationFilesystemEntry] {
            Array((directoryEntries[directory] ?? []).prefix(max))
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

    // omp's real id grammar: a UUIDv7 (version nibble 7) in 8-4-4-4-12 hex.
    private let v7Id = "019f0b94-be86-7000-bf88-d9b6dcae2616"
    private let v7Id2 = "019f0ab6-19f2-7000-88f8-5c62ba55bc76"

    /// Build the sessions-root key exactly as `OmpScraper.sessionsRoot()` does
    /// (chained `appendingPathComponent(isDirectory: true)`), so the MockFS
    /// dictionary lookup keyed on this URL matches the scraper's lookup. A flat
    /// `URL(fileURLWithPath:)` would differ by a trailing slash and miss.
    private func sessionsRoot(_ home: URL) -> URL {
        home.appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private func ompEntry(
        slug: String, fileName: String, mtime: Date, size: Int64, root: URL
    ) -> ConversationFilesystemEntry {
        ConversationFilesystemEntry(
            url: root.appendingPathComponent(slug).appendingPathComponent(fileName),
            fileName: fileName,
            mtime: mtime,
            size: size
        )
    }

    // MARK: - Scraper

    func testOmpScraperParsesUUIDv7AfterLastUnderscore() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = sessionsRoot(mock.home!)
        let now = Date()
        mock.recursiveEntries[root] = [
            ompEntry(slug: "-work-proj",
                     fileName: "2026-06-28T00-15-25-318Z_\(v7Id).jsonl",
                     mtime: now, size: 1024, root: root),
            ompEntry(slug: "-other-proj",
                     fileName: "2026-06-27T20-12-14-194Z_\(v7Id2).jsonl",
                     mtime: now.addingTimeInterval(-60), size: 2048, root: root)
        ]
        let scraper = OmpScraper(filesystem: mock)
        // No cwd → whole-tree recursive fallback (the cwd-scoped path is
        // covered by testOmpScraperScopesToCwdSlugDirectory).
        let candidates = scraper.candidates()
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].id, v7Id, "id is the UUID after the last underscore")
        XCTAssertEqual(candidates[1].id, v7Id2)
        XCTAssertNil(candidates[0].cwd, "no cwd passed → not stamped")
    }

    func testOmpScraperRejectsNonUUIDAndNoUnderscoreFilenames() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = sessionsRoot(mock.home!)
        mock.recursiveEntries[root] = [
            // valid
            ompEntry(slug: "-work", fileName: "2026-06-28T00-00-00-000Z_\(v7Id).jsonl",
                     mtime: Date(), size: 10, root: root),
            // trailing segment after last `_` is not a UUID
            ompEntry(slug: "-work", fileName: "2026-06-28T00-00-00-000Z_garbage.jsonl",
                     mtime: Date(), size: 10, root: root),
            // no underscore at all → rejected
            ompEntry(slug: "-work", fileName: "noUnderscore.jsonl",
                     mtime: Date(), size: 10, root: root)
        ]
        let scraper = OmpScraper(filesystem: mock)
        let candidates = scraper.candidates()
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].id, v7Id)
    }

    func testOmpScraperExcludesLogSiblingsViaExtensionFilter() {
        // The recursive walker only surfaces `.jsonl`; the per-session
        // `*.log` files in the sibling subdir never reach the scraper. We
        // model that by including a `.log` entry and asserting it's filtered.
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = sessionsRoot(mock.home!)
        mock.recursiveEntries[root] = [
            ompEntry(slug: "-work", fileName: "2026-06-28T00-00-00-000Z_\(v7Id).jsonl",
                     mtime: Date(), size: 10, root: root),
            ompEntry(slug: "-work/2026-06-28T00-00-00-000Z_\(v7Id)",
                     fileName: "1.bash-original.log",
                     mtime: Date(), size: 10, root: root)
        ]
        let scraper = OmpScraper(filesystem: mock)
        let candidates = scraper.candidates()
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].id, v7Id)
    }

    func testOmpScraperEmptyWhenDirectoryMissing() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        // No recursiveEntries keyed for the sessions root.
        let scraper = OmpScraper(filesystem: mock)
        XCTAssertTrue(scraper.candidates().isEmpty)
    }

    /// omp's slug strips the home prefix and maps `/`→`-` (verified against the
    /// real store; differs from pi's full-path `--<…>--` convention).
    func testOmpSessionSlugStripsHomeAndMapsSlashes() {
        let home = URL(fileURLWithPath: "/Users/atin")
        XCTAssertEqual(
            OmpScraper.sessionSlug(forCwd: "/Users/atin/Projects/Stage11/code/c11", homeDirectory: home),
            "-Projects-Stage11-code-c11")
        XCTAssertEqual(
            OmpScraper.sessionSlug(forCwd: "/Users/atin/Projects/GLM-UniHub", homeDirectory: home),
            "-Projects-GLM-UniHub", "existing dashes + case preserved")
        XCTAssertEqual(
            OmpScraper.sessionSlug(forCwd: "/work/x", homeDirectory: home),
            "-work-x", "cwd outside home → full path mapped")
    }

    /// When a cwd is known, scope to that cwd's slug dir, and filter sibling
    /// `*.log` entries out by suffix (the slug-dir listing is unfiltered).
    func testOmpScraperScopesToCwdSlugDirectory() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = sessionsRoot(mock.home!)
        let cwd = "/Users/test/work/mine"
        let slugDir = root.appendingPathComponent(
            OmpScraper.sessionSlug(forCwd: cwd, homeDirectory: mock.home), isDirectory: true)
        let name = "2026-06-28T00-15-25-318Z_\(v7Id).jsonl"
        mock.directoryEntries[slugDir] = [
            ConversationFilesystemEntry(url: slugDir.appendingPathComponent(name), fileName: name, mtime: Date(), size: 1024),
            ConversationFilesystemEntry(url: slugDir.appendingPathComponent("1.bash.log"), fileName: "1.bash.log", mtime: Date(), size: 10)
        ]
        let candidates = OmpScraper(filesystem: mock).candidates(cwd: cwd)
        XCTAssertEqual(candidates.map(\.id), [v7Id], "scoped to cwd slug dir; .log filtered out")
        XCTAssertEqual(candidates[0].cwd, cwd)
    }

    /// C11-156 regression: a newer session in a DIFFERENT project's slug dir
    /// must not leak into this cwd's candidates (the cross-project bleed bug).
    func testOmpScraperDoesNotLeakSessionsFromOtherCwds() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = sessionsRoot(mock.home!)
        let mineDir = root.appendingPathComponent(
            OmpScraper.sessionSlug(forCwd: "/Users/test/mine", homeDirectory: mock.home), isDirectory: true)
        let otherDir = root.appendingPathComponent(
            OmpScraper.sessionSlug(forCwd: "/Users/test/other", homeDirectory: mock.home), isDirectory: true)
        let now = Date()
        let mineName = "2026-06-28T00-00-00-000Z_\(v7Id).jsonl"
        let otherName = "2026-06-28T00-30-00-000Z_\(v7Id2).jsonl"
        mock.directoryEntries[mineDir] = [
            ConversationFilesystemEntry(url: mineDir.appendingPathComponent(mineName), fileName: mineName, mtime: now.addingTimeInterval(-3600), size: 1)
        ]
        mock.directoryEntries[otherDir] = [
            ConversationFilesystemEntry(url: otherDir.appendingPathComponent(otherName), fileName: otherName, mtime: now, size: 1)
        ]
        let candidates = OmpScraper(filesystem: mock).candidates(cwd: "/Users/test/mine")
        XCTAssertEqual(candidates.map(\.id), [v7Id], "only this cwd's session; newer foreign session not leaked")
    }

    // MARK: - Strategy

    private func candidate(id: String, mtime: Date, cwd: String?) -> ScrapeCandidate {
        ScrapeCandidate(id: id, filePath: "/p/\(id).jsonl", mtime: mtime, size: 1, cwd: cwd)
    }

    func testOmpCaptureSingleCandidateMarksAlive() {
        let strategy = OmpStrategy()
        let claimTime = Date().addingTimeInterval(-100)
        let inputs = ConversationStrategyInputs(
            surfaceId: "surface:1",
            cwd: "/work/proj",
            lastActivityTimestamp: claimTime,
            wrapperClaim: ConversationRef(
                kind: "omp", id: "placeholder", placeholder: true,
                cwd: "/work/proj", capturedAt: claimTime,
                capturedVia: .wrapperClaim, state: .alive),
            scrapeCandidates: [
                candidate(id: v7Id, mtime: Date(), cwd: "/work/proj")
            ])
        let ref = strategy.capture(inputs: inputs)
        XCTAssertEqual(ref?.id, v7Id)
        XCTAssertEqual(ref?.state, .alive)
        XCTAssertFalse(ref?.placeholder ?? true)
    }

    func testOmpResumeEmitsResumeFlagWithSpecificId() {
        let strategy = OmpStrategy()
        let ref = ConversationRef(
            kind: "omp", id: v7Id, placeholder: false,
            cwd: "/work/proj", capturedAt: Date(),
            capturedVia: .scrape, state: .alive)
        guard case .typeCommand(let text, let submit) = strategy.resume(ref: ref) else {
            XCTFail("expected typeCommand"); return
        }
        XCTAssertEqual(text, "omp --resume='\(v7Id)'")
        XCTAssertTrue(text.contains(v7Id), "must resume the specific id, not a --last-style flag")
        XCTAssertTrue(submit)
    }

    func testOmpAmbiguousCandidatesSkipResume() {
        let strategy = OmpStrategy()
        let claimTime = Date().addingTimeInterval(-100)
        let now = Date()
        let inputs = ConversationStrategyInputs(
            surfaceId: "surface:1",
            cwd: "/work/proj",
            lastActivityTimestamp: claimTime,
            wrapperClaim: ConversationRef(
                kind: "omp", id: "placeholder", placeholder: true,
                cwd: "/work/proj", capturedAt: claimTime,
                capturedVia: .wrapperClaim, state: .alive),
            scrapeCandidates: [
                candidate(id: v7Id, mtime: now, cwd: "/work/proj"),
                candidate(id: v7Id2, mtime: now.addingTimeInterval(-5), cwd: "/work/proj")
            ])
        let ref = strategy.capture(inputs: inputs)
        XCTAssertEqual(ref?.state, .unknown, "ambiguity ⇒ unknown")
        XCTAssertEqual(ref?.id, v7Id, "chose newest")
        XCTAssertTrue(ref?.diagnosticReason?.contains("ambiguous") ?? false)
        guard case .skip(let reason) = strategy.resume(ref: ref!) else {
            XCTFail("ambiguous ref must not auto-resume"); return
        }
        XCTAssertEqual(reason, "ambiguous")
    }

    /// The wrapper-claim time floor disambiguates the common "stale sessions
    /// accumulated in a cwd" case (the latent bug pi hit). At cold restore
    /// (`lastActivityTimestamp: nil`) the claim is the only floor: a session
    /// older than the launch claim is dropped, so the single post-claim active
    /// session resolves to `.alive` and resume fires — instead of `.unknown`.
    func testOmpWrapperClaimFloorsStaleSessionToResolveActive() {
        let strategy = OmpStrategy()
        let now = Date()
        let claimTime = now.addingTimeInterval(-60)
        let inputs = ConversationStrategyInputs(
            surfaceId: "surface:1",
            cwd: "/work/proj",
            lastActivityTimestamp: nil,
            wrapperClaim: ConversationRef(
                kind: "omp", id: "placeholder", placeholder: true,
                cwd: "/work/proj", capturedAt: claimTime,
                capturedVia: .wrapperClaim, state: .alive),
            scrapeCandidates: [
                candidate(id: v7Id, mtime: now, cwd: "/work/proj"),                            // active (post-claim)
                candidate(id: v7Id2, mtime: now.addingTimeInterval(-3600), cwd: "/work/proj")  // stale (pre-claim)
            ])
        let ref = strategy.capture(inputs: inputs)
        XCTAssertEqual(ref?.state, .alive, "claim floors the stale session → resolves instead of .unknown")
        XCTAssertEqual(ref?.id, v7Id)
        XCTAssertFalse(ref?.placeholder ?? true)
        guard case .typeCommand(let text, _) = strategy.resume(ref: ref!) else {
            XCTFail("expected typeCommand"); return
        }
        XCTAssertEqual(text, "omp --resume='\(v7Id)'")
    }

    func testOmpResumeSkipsPlaceholder() {
        let strategy = OmpStrategy()
        let ref = ConversationRef(
            kind: "omp", id: v7Id, placeholder: true,
            cwd: nil, capturedAt: Date(),
            capturedVia: .wrapperClaim, state: .alive)
        guard case .skip = strategy.resume(ref: ref) else {
            XCTFail("placeholder must skip"); return
        }
    }

    func testOmpResumeSkipsInvalidId() {
        let strategy = OmpStrategy()
        let ref = ConversationRef(
            kind: "omp", id: "not-a-uuid", placeholder: false,
            cwd: nil, capturedAt: Date(),
            capturedVia: .scrape, state: .alive)
        guard case .skip = strategy.resume(ref: ref) else {
            XCTFail("invalid id must skip"); return
        }
    }

    func testOmpIsValidIdAcceptsUUIDv7() {
        let strategy = OmpStrategy()
        XCTAssertTrue(strategy.isValidId(v7Id))
        XCTAssertFalse(strategy.isValidId("nope"))
    }

    /// Crash-recovery: `transcriptExists` confirms the session file is on disk
    /// (cwd-scoped) so a crashed omp ref is promoted to `.suspended` and resumes
    /// instead of being forced to `.unknown`.
    func testOmpTranscriptExistsVerifiesSessionFileOnDisk() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = sessionsRoot(mock.home!)
        let cwd = "/Users/test/proj"
        let slugDir = root.appendingPathComponent(
            OmpScraper.sessionSlug(forCwd: cwd, homeDirectory: mock.home), isDirectory: true)
        let name = "2026-06-28T00-15-25-318Z_\(v7Id).jsonl"
        mock.directoryEntries[slugDir] = [
            ConversationFilesystemEntry(url: slugDir.appendingPathComponent(name), fileName: name, mtime: Date(), size: 1)
        ]
        let strategy = OmpStrategy()
        let present = ConversationRef(kind: "omp", id: v7Id, placeholder: false, cwd: cwd, capturedVia: .scrape, state: .suspended)
        XCTAssertEqual(strategy.transcriptExists(for: present, filesystem: mock), true)
        let absent = ConversationRef(kind: "omp", id: v7Id2, placeholder: false, cwd: cwd, capturedVia: .scrape, state: .suspended)
        XCTAssertEqual(strategy.transcriptExists(for: absent, filesystem: mock), false)
    }

    // MARK: - Registry wiring

    func testOmpRegisteredInBothV1Registries() {
        XCTAssertTrue(ConversationStrategyRegistry.v1.contains(kind: "omp"))
        XCTAssertTrue(ConversationScraperRegistry.v1().contains(kind: "omp"))
    }
}
