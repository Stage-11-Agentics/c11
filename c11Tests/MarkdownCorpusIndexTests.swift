import Foundation
import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class MarkdownCorpusIndexTests: XCTestCase {
    func testRepositoryRootFallsBackToDocumentDirectory() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let repo = temp.appendingPathComponent("repo", isDirectory: true)
        let nested = repo.appendingPathComponent("docs/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: repo.appendingPathComponent(".git"))
        let document = nested.appendingPathComponent("reader.md")
        try Data("# Reader".utf8).write(to: document)
        XCTAssertEqual(MarkdownCorpusIndexer.corpusRoot(for: document).path, repo.path)

        let plain = temp.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let untracked = plain.appendingPathComponent("notes.md")
        try Data("# Notes".utf8).write(to: untracked)
        XCTAssertEqual(MarkdownCorpusIndexer.corpusRoot(for: untracked).path, plain.path)
    }

    func testIndexSkipsBuildTreesSymlinksAndFilesOverCaps() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let external = temp.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("# Secret".utf8).write(to: external.appendingPathComponent("secret.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: external)
        let accepted = root.appendingPathComponent("docs/a.md")
        try FileManager.default.createDirectory(at: accepted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Reader\n\n[Setup](b.md#install)\n".utf8).write(to: accepted)
        try Data("# Install\n".utf8).write(to: root.appendingPathComponent("docs/b.md"))
        for name in [".git", "node_modules", "DerivedData", "build", "dist", ".build"] {
            let skipped = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: skipped, withIntermediateDirectories: true)
            try Data("# Skip".utf8).write(to: skipped.appendingPathComponent("hidden.md"))
        }
        try Data(repeating: 0x78, count: 33).write(to: root.appendingPathComponent("oversized.md"))

        var limits = MarkdownCorpusIndexer.Limits()
        limits.maximumFileBytes = 32
        limits.maximumTotalBytes = 64
        let indexer = MarkdownCorpusIndexer(fileURL: accepted, limits: limits) { _ in }
        let snapshot = await scan(indexer)
        XCTAssertEqual(snapshot.documents.map(\.relativePath), ["docs/a.md", "docs/b.md"])
        XCTAssertFalse(snapshot.documents.contains { $0.path.contains("hidden.md") || $0.path.contains("secret.md") })
        XCTAssertTrue(snapshot.truncated)
    }

    func testBoundsAndIncrementalRescanReuseUnchangedDocuments() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        try Data("# Alpha\n\n[Beta](b.md#beta)\n".utf8).write(to: a)
        try Data("# Beta\n".utf8).write(to: b)
        var limits = MarkdownCorpusIndexer.Limits()
        limits.maximumDocuments = 1
        let indexer = MarkdownCorpusIndexer(fileURL: a, limits: limits) { _ in }

        let first = await scan(indexer)
        XCTAssertEqual(first.documents.map(\.relativePath), ["a.md"])
        XCTAssertTrue(first.truncated)
        XCTAssertEqual(first.filesReparsed, 1)
        let unchanged = await scan(indexer)
        XCTAssertEqual(unchanged.filesReparsed, 1, "unchanged Markdown reuses its parsed snapshot")

        try Data("# Alpha changed\n\n[Beta](b.md#beta)\n".utf8).write(to: a)
        let changed = await scan(indexer)
        XCTAssertEqual(changed.filesReparsed, 2)
        XCTAssertEqual(changed.documents.first?.headings.first?.text, "Alpha changed")

        var byteLimits = MarkdownCorpusIndexer.Limits()
        byteLimits.maximumFileBytes = 128
        byteLimits.maximumTotalBytes = 12
        let byteCapped = await scan(MarkdownCorpusIndexer(fileURL: a, limits: byteLimits) { _ in })
        XCTAssertEqual(byteCapped.documents.map(\.relativePath), ["b.md"])
        XCTAssertTrue(byteCapped.truncated)
    }

    func testBacklinksPreserveSourceSectionAndResolveTicketCardsReadOnly() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let board = root.appendingPathComponent(".lattice", isDirectory: true)
        let tasks = board.appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        let taskID = "task_01KPP7QBZ3NJMXS4C9NA2XW01X"
        let codeTaskID = "task_01KPP7QBZ3NJMXS4C9NA2XW01Y"
        let idsURL = board.appendingPathComponent("ids.json")
        let taskURL = tasks.appendingPathComponent("\(taskID).json")
        let codeTaskURL = tasks.appendingPathComponent("\(codeTaskID).json")
        try Data(#"{"map":{"C11-123":"\#(taskID)","C11-999":"\#(codeTaskID)"}}"#.utf8).write(to: idsURL)
        try Data(#"{"short_id":"C11-123","title":"Local task","status":"in_progress"}"#.utf8).write(to: taskURL)
        try Data(#"{"short_id":"C11-999","title":"Code only","status":"open"}"#.utf8).write(to: codeTaskURL)
        let target = root.appendingPathComponent("target.md")
        let source = root.appendingPathComponent("source.md")
        try Data("# Install\n".utf8).write(to: target)
        try Data("# Notes\n\n## Setup\nSee [install](target.md#install) and C11-123; literal `C11-999`.\n".utf8).write(to: source)
        let beforeIDs = try Data(contentsOf: idsURL)
        let beforeTask = try Data(contentsOf: taskURL)
        let indexer = MarkdownCorpusIndexer(fileURL: target) { _ in }
        let snapshot = await scan(indexer)
        let references = snapshot.backlinks(to: target.path, fragment: "install")
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?.sourcePath, source.path)
        XCTAssertEqual(references.first?.sourceSection, "Setup")
        XCTAssertEqual(references.first?.sourceSectionSlug, "setup")
        XCTAssertEqual(snapshot.tickets["C11-123"], MarkdownTicketCard(title: "Local task", status: "in_progress"))
        XCTAssertNil(snapshot.tickets["C11-999"], "inline code IDs stay plain text")
        XCTAssertEqual(try Data(contentsOf: idsURL), beforeIDs)
        XCTAssertEqual(try Data(contentsOf: taskURL), beforeTask)

        let plainRoot = temp.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plainRoot, withIntermediateDirectories: true)
        let plainDoc = plainRoot.appendingPathComponent("plain.md")
        try Data("# Plain\nC11-123".utf8).write(to: plainDoc)
        let noBoard = await scan(MarkdownCorpusIndexer(fileURL: plainDoc) { _ in })
        XCTAssertTrue(noBoard.tickets.isEmpty)
    }

    func testFSEventsRefreshAddAndDeleteMarkdown() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let initial = root.appendingPathComponent("reader.md")
        let added = root.appendingPathComponent("added.md")
        try Data("# Reader".utf8).write(to: initial)

        let appeared = expectation(description: "FSEvents indexes the added document")
        let disappeared = expectation(description: "FSEvents removes the deleted document")
        let indexer = MarkdownCorpusIndexer(fileURL: initial) { snapshot in
            if snapshot.containsDocument(path: added.path) { appeared.fulfill() }
            if snapshot.revision > 1 && !snapshot.containsDocument(path: added.path) { disappeared.fulfill() }
        }
        indexer.start()
        try Data("# Added".utf8).write(to: added)
        await fulfillment(of: [appeared], timeout: 10)
        try FileManager.default.removeItem(at: added)
        await fulfillment(of: [disappeared], timeout: 10)
        indexer.stop()
    }

    private func scan(_ indexer: MarkdownCorpusIndexer) async -> MarkdownCorpusSnapshot {
        await withCheckedContinuation { continuation in
            indexer.refreshNow { continuation.resume(returning: $0) }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-corpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
