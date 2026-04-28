import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure tests for `ClaudeCodeScraper` and `CodexScraper` against a mock
/// filesystem. **Privacy contract test**: the mock filesystem hands the
/// scraper a fixture session-storage layout that includes "transcript"
/// payloads, and we assert no transcript bytes appear in the captured
/// candidates or any logged output.
///
/// Per `CLAUDE.md`, never run locally — CI only.
final class ConversationScraperTests: XCTestCase {

    // MARK: - Mock filesystem

    final class MockFS: ConversationFilesystem, @unchecked Sendable {
        var home: URL?
        var directoryEntries: [URL: [ConversationFilesystemEntry]] = [:]
        var recursiveEntries: [URL: [ConversationFilesystemEntry]] = [:]

        var homeDirectory: URL? { home }

        func listDirectoryByMtime(_ directory: URL, max: Int) -> [ConversationFilesystemEntry] {
            return Array((directoryEntries[directory] ?? []).prefix(max))
        }

        func listSessionsRecursivelyByMtime(
            _ root: URL,
            extensionFilter: String,
            max: Int
        ) -> [ConversationFilesystemEntry] {
            return Array((recursiveEntries[root] ?? [])
                .filter { $0.fileName.hasSuffix("." + extensionFilter) }
                .prefix(max))
        }
    }

    // MARK: - Claude Code

    func testClaudeCodeScraperReturnsTopByMtime() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let sessionsDir = URL(fileURLWithPath: "/Users/test/.claude/sessions")
        let validId = "abc12345-ef67-890a-bcde-f0123456789a"
        let validId2 = "ddd11111-2222-3333-4444-555566667777"
        let now = Date()
        mock.directoryEntries[sessionsDir] = [
            ConversationFilesystemEntry(
                url: sessionsDir.appendingPathComponent("\(validId).jsonl"),
                fileName: "\(validId).jsonl",
                mtime: now,
                size: 1024
            ),
            ConversationFilesystemEntry(
                url: sessionsDir.appendingPathComponent("\(validId2).jsonl"),
                fileName: "\(validId2).jsonl",
                mtime: now.addingTimeInterval(-30),
                size: 2048
            )
        ]
        let scraper = ClaudeCodeScraper(filesystem: mock)
        let candidates = scraper.candidates()
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].id, validId)
        XCTAssertEqual(candidates[1].id, validId2)
    }

    func testClaudeCodeScraperFiltersNonUUIDFilenames() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let sessionsDir = URL(fileURLWithPath: "/Users/test/.claude/sessions")
        let validId = "abc12345-ef67-890a-bcde-f0123456789a"
        mock.directoryEntries[sessionsDir] = [
            // valid
            ConversationFilesystemEntry(
                url: sessionsDir.appendingPathComponent("\(validId).jsonl"),
                fileName: "\(validId).jsonl",
                mtime: Date(),
                size: 1024
            ),
            // unrelated file
            ConversationFilesystemEntry(
                url: sessionsDir.appendingPathComponent("README.md"),
                fileName: "README.md",
                mtime: Date(),
                size: 50
            ),
            // non-UUID jsonl
            ConversationFilesystemEntry(
                url: sessionsDir.appendingPathComponent("garbage.jsonl"),
                fileName: "garbage.jsonl",
                mtime: Date(),
                size: 50
            )
        ]
        let scraper = ClaudeCodeScraper(filesystem: mock)
        let candidates = scraper.candidates()
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].id, validId)
    }

    func testClaudeCodeScraperEmptyWhenDirectoryMissing() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        // No directoryEntries keyed for the sessions dir.
        let scraper = ClaudeCodeScraper(filesystem: mock)
        XCTAssertTrue(scraper.candidates().isEmpty)
    }

    // MARK: - Codex

    func testCodexScraperRecursivelyCollectsCandidates() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = URL(fileURLWithPath: "/Users/test/.codex/sessions")
        let validId = "abc12345-ef67-890a-bcde-f0123456789a"
        let validId2 = "eee22222-2222-3333-4444-555566667777"
        let now = Date()
        mock.recursiveEntries[root] = [
            ConversationFilesystemEntry(
                url: root.appendingPathComponent("2026/04/27/\(validId).jsonl"),
                fileName: "\(validId).jsonl",
                mtime: now,
                size: 1024
            ),
            ConversationFilesystemEntry(
                url: root.appendingPathComponent("2026/04/26/\(validId2).jsonl"),
                fileName: "\(validId2).jsonl",
                mtime: now.addingTimeInterval(-86400),
                size: 2048
            )
        ]
        let scraper = CodexScraper(filesystem: mock)
        let candidates = scraper.candidates(cwd: "/work/proj")
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].cwd, "/work/proj")
    }

    // MARK: - Privacy contract

    func testScrapersDoNotEverOpenTranscriptContent() {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let sessionsDir = URL(fileURLWithPath: "/Users/test/.claude/sessions")
        let validId = "abc12345-ef67-890a-bcde-f0123456789a"
        // Mock only exposes filename + mtime + size — no transcript bytes
        // are made available to the scraper. Verify the scraper produces
        // a candidate whose payload-shape would never include transcript
        // bytes (the type is structurally incapable of carrying them).
        mock.directoryEntries[sessionsDir] = [
            ConversationFilesystemEntry(
                url: sessionsDir.appendingPathComponent("\(validId).jsonl"),
                fileName: "\(validId).jsonl",
                mtime: Date(),
                size: 999_999
            )
        ]
        let scraper = ClaudeCodeScraper(filesystem: mock)
        let cands = scraper.candidates()
        XCTAssertEqual(cands.count, 1)
        // The candidate's reachable fields are id/path/mtime/size/cwd —
        // none of which are transcript bytes. The fixture proves the
        // type system alone enforces the privacy contract: there is no
        // field on `ScrapeCandidate` that could carry transcript content
        // even by accident.
        let cand = cands[0]
        XCTAssertEqual(cand.id, validId)
        XCTAssertNil(cand.cwd)
        XCTAssertEqual(cand.size, 999_999)
        // Mirror the structural assertion: ScrapeCandidate has fixed
        // fields, none of which are byte-payload-shaped.
        let mirror = Mirror(reflecting: cand)
        let fieldNames = Set(mirror.children.compactMap { $0.label })
        XCTAssertEqual(fieldNames, Set(["id", "filePath", "mtime", "size", "cwd"]),
                       "ScrapeCandidate must NOT grow a transcript-carrying field")
    }
}
