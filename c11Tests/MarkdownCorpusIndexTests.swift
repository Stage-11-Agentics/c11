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

    func testNearestFirstBudgetsKeepOpenDirectoryAheadOfLexicalNoiseAndIgnoreWorktrees() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let noise = root.appendingPathComponent("a-noise", isDirectory: true)
        let ignored = root.appendingPathComponent("c11-worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: noise, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try Data("c11-worktrees/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try runGit(root, ["init", "-q"])

        let reader = docs.appendingPathComponent("reader.md")
        let nearby = docs.appendingPathComponent("nearby.md")
        try Data("# Current\n## Current details\n".utf8).write(to: reader)
        try Data("# Nearby\n".utf8).write(to: nearby)
        for index in 0..<8 {
            try Data("# Noise \(index)\n## Noise details\n".utf8)
                .write(to: noise.appendingPathComponent("\(index).md"))
        }
        try Data("# Ignored duplicate\n".utf8).write(to: ignored.appendingPathComponent("reader.md"))

        var limits = MarkdownCorpusIndexer.Limits()
        limits.maximumVisitedEntries = 3
        limits.maximumDocuments = 2
        limits.maximumTotalHeadings = 3
        limits.maximumHeadingsPerDocument = 2
        let snapshot = await scan(MarkdownCorpusIndexer(fileURL: reader, limits: limits) { _ in })

        XCTAssertEqual(snapshot.documents.map(\.relativePath), ["docs/reader.md", "docs/nearby.md"])
        XCTAssertEqual(snapshot.documents.first?.headings.map(\.text), ["Current", "Current details"])
        XCTAssertEqual(snapshot.documents.last?.headings.map(\.text), ["Nearby"])
        XCTAssertFalse(snapshot.documents.contains { $0.relativePath.hasPrefix("c11-worktrees/") })
        XCTAssertTrue(snapshot.truncated, "the visited-entry cap should report the ignored lexical-noise corpus as truncated")
    }

    func testHeadingParserIgnoresFrontmatterAndIndentedCodeAndUsesViewerSlugs() throws {
        let root = URL(fileURLWithPath: "/tmp/markdown-parser-fixture", isDirectory: true)
        let file = root.appendingPathComponent("reader.md")
        let source = """
        ---
        description: metadata is not a heading
        ---

        # Guide

        ## `dispatch_log`

        ## _Emphasis_

            # comment in indented code
            [fake](missing.md)

        ## Real section
        """
        let parsed = MarkdownCorpusParser.parse(
            source,
            fileURL: file,
            rootURL: root,
            maximumHeadings: 20,
            maximumLinks: 20,
            maximumTicketIDs: 20
        )
        XCTAssertEqual(parsed.document.headings.map(\.text), ["Guide", "dispatch_log", "Emphasis", "Real section"])
        XCTAssertEqual(parsed.document.headings.map(\.slug), ["guide", "dispatch_log", "emphasis", "real-section"])
        XCTAssertTrue(parsed.document.links.isEmpty, "links inside indented code are inert")

        let pathological = MarkdownCorpusParser.parse(
            "# Safe\n\n" + String(repeating: "[", count: 64 * 1024),
            fileURL: file,
            rootURL: root,
            maximumHeadings: 20,
            maximumLinks: 20,
            maximumTicketIDs: 20
        )
        XCTAssertTrue(pathological.document.links.isEmpty)
        XCTAssertTrue(pathological.linksTruncated, "oversized lines are skipped before the link regex runs")
    }

    func testCorpusNavigationValidationRejectsUnlistedTargetsAndUnrelatedBacklinks() {
        let root = URL(fileURLWithPath: "/tmp/markdown-navigation-fixture", isDirectory: true)
        let reader = root.appendingPathComponent("reader.md")
        let source = root.appendingPathComponent("source.md")
        let readerDocument = MarkdownCorpusDocument(
            path: reader.path, relativePath: "reader.md", title: "reader.md",
            headings: [MarkdownCorpusHeading(level: 2, text: "Install", slug: "install", line: 3)],
            links: [], ticketIDs: []
        )
        let sourceDocument = MarkdownCorpusDocument(
            path: source.path, relativePath: "source.md", title: "source.md",
            headings: [MarkdownCorpusHeading(level: 2, text: "Setup", slug: "setup", line: 3)],
            links: [], ticketIDs: []
        )
        let link = MarkdownCorpusLink(
            sourcePath: source.path, sourceTitle: "source.md", sourceSection: "Setup", sourceSectionSlug: "setup",
            line: 4, text: "reader", targetPath: reader.path, targetFragment: "install"
        )
        let snapshot = MarkdownCorpusSnapshot(
            rootPath: root.path, documents: [readerDocument, sourceDocument], links: [link], tickets: [:],
            truncated: false, revision: 1, filesReparsed: 2
        )

        XCTAssertTrue(snapshot.validatesNavigation(path: reader.path, fragment: "install", origin: .palette, currentPath: reader.path))
        XCTAssertFalse(snapshot.validatesNavigation(path: reader.path, fragment: "missing", origin: .palette, currentPath: reader.path))
        XCTAssertFalse(snapshot.validatesNavigation(path: root.appendingPathComponent("outside.md").path, fragment: nil, origin: .palette, currentPath: reader.path))
        XCTAssertTrue(snapshot.validatesNavigation(path: source.path, fragment: "setup", origin: .backlink, currentPath: reader.path))
        XCTAssertFalse(snapshot.validatesNavigation(path: reader.path, fragment: "install", origin: .backlink, currentPath: reader.path))
        XCTAssertFalse(snapshot.validatesNavigation(path: source.path, fragment: "setup", origin: .backlink, currentPath: source.path))
        XCTAssertFalse(snapshot.validatesNavigation(path: reader.path, fragment: nil, origin: .documentLink, currentPath: reader.path))
    }

    func testBacklinksMatchResolvedSymlinkedDocumentPaths() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.md")
        let source = root.appendingPathComponent("source.md")
        let alias = root.appendingPathComponent("target-alias.md")
        try Data("# Target\n".utf8).write(to: target)
        try Data("# Source\n\n[Target](target.md)\n".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let snapshot = await scan(MarkdownCorpusIndexer(fileURL: alias) { _ in })
        XCTAssertEqual(snapshot.backlinks(to: alias.path).map(\.sourcePath), [source.path])
        XCTAssertEqual(snapshot.backlinks(to: target.path).count, 1)
        XCTAssertFalse(snapshot.documents.contains { $0.path == alias.path }, "the symlink alias is resolved for lookups but never indexed as a second document")
    }

    func testIncrementalRescanReallocatesGlobalHeadingBudget() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let first = root.appendingPathComponent("a.md")
        let second = root.appendingPathComponent("b.md")
        try Data("# First\n".utf8).write(to: first)
        try Data("# Beta\n## Gamma\n".utf8).write(to: second)
        var limits = MarkdownCorpusIndexer.Limits()
        limits.maximumTotalHeadings = 2
        let indexer = MarkdownCorpusIndexer(fileURL: first, limits: limits) { _ in }

        let initial = await scan(indexer)
        XCTAssertEqual(initial.documents.flatMap(\.headings).map(\.text), ["First", "Beta"])
        XCTAssertTrue(initial.truncated)

        try Data("No heading now\n".utf8).write(to: first)
        let reallocated = await scan(indexer)
        XCTAssertEqual(reallocated.documents.flatMap(\.headings).map(\.text), ["Beta", "Gamma"])
        XCTAssertEqual(reallocated.filesReparsed, 4, "the later cached file is reparsed when its bounded allocation expands")
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
        let docsTaskID = "task_01KPP7QBZ3NJMXS4C9NA2XW01Z"
        let idsURL = board.appendingPathComponent("ids.json")
        let taskURL = tasks.appendingPathComponent("\(taskID).json")
        let codeTaskURL = tasks.appendingPathComponent("\(codeTaskID).json")
        let docsTaskURL = tasks.appendingPathComponent("\(docsTaskID).json")
        try Data(#"{"map":{"C11-123":"\#(taskID)","C11-999":"\#(codeTaskID)","DOCS-321":"\#(docsTaskID)"}}"#.utf8).write(to: idsURL)
        try Data(#"{"short_id":"C11-123","title":"Local task","status":"in_progress"}"#.utf8).write(to: taskURL)
        try Data(#"{"short_id":"C11-999","title":"Code only","status":"open"}"#.utf8).write(to: codeTaskURL)
        try Data(#"{"short_id":"DOCS-321","title":"Docs task","status":"done"}"#.utf8).write(to: docsTaskURL)
        let target = root.appendingPathComponent("target.md")
        let source = root.appendingPathComponent("source.md")
        try Data("# Install\n".utf8).write(to: target)
        try Data("# Notes\n\n## Setup\nSee [install](target.md#install), C11-123 and DOCS-321; literal `C11-999`.\n".utf8).write(to: source)
        let beforeIDs = try Data(contentsOf: idsURL)
        let beforeTask = try Data(contentsOf: taskURL)
        let beforeDocsTask = try Data(contentsOf: docsTaskURL)
        let indexer = MarkdownCorpusIndexer(fileURL: target) { _ in }
        let snapshot = await scan(indexer)
        let references = snapshot.backlinks(to: target.path, fragment: "install")
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?.sourcePath, source.path)
        XCTAssertEqual(references.first?.sourceSection, "Setup")
        XCTAssertEqual(references.first?.sourceSectionSlug, "setup")
        XCTAssertEqual(snapshot.tickets["C11-123"], MarkdownTicketCard(title: "Local task", status: "in_progress"))
        XCTAssertEqual(snapshot.tickets["DOCS-321"], MarkdownTicketCard(title: "Docs task", status: "done"))
        XCTAssertNil(snapshot.tickets["C11-999"], "inline code IDs stay plain text")
        XCTAssertEqual(try Data(contentsOf: idsURL), beforeIDs)
        XCTAssertEqual(try Data(contentsOf: taskURL), beforeTask)
        XCTAssertEqual(try Data(contentsOf: docsTaskURL), beforeDocsTask)

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

        let initialPublished = expectation(description: "initial corpus scan completes before the write")
        let appeared = expectation(description: "FSEvents indexes the added document")
        let disappeared = expectation(description: "FSEvents removes the deleted document")
        let indexer = MarkdownCorpusIndexer(fileURL: initial) { snapshot in
            if snapshot.revision == 1 { initialPublished.fulfill() }
            if snapshot.containsDocument(path: added.path) { appeared.fulfill() }
            if snapshot.revision > 1 && !snapshot.containsDocument(path: added.path) { disappeared.fulfill() }
        }
        indexer.start()
        await fulfillment(of: [initialPublished], timeout: 10)
        try Data("# Added".utf8).write(to: added)
        await fulfillment(of: [appeared], timeout: 10)
        try FileManager.default.removeItem(at: added)
        await fulfillment(of: [disappeared], timeout: 10)
        indexer.stop()
    }

    func testNonMarkdownFilesystemWriteAndUnchangedRescanDoNotPublish() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var stored = 0
            var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
            func increment() { lock.lock(); stored += 1; lock.unlock() }
        }

        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(root, ["init", "-q"])
        try Data("ignored/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let reader = root.appendingPathComponent("reader.md")
        let nonMarkdown = root.appendingPathComponent("output.txt")
        let ignoredDirectory = root.appendingPathComponent("ignored", isDirectory: true)
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
        let ignoredMarkdown = ignoredDirectory.appendingPathComponent("noise.md")
        try Data("# Reader\n".utf8).write(to: reader)
        let initialPublished = expectation(description: "initial snapshot")
        let unexpectedPublish = expectation(description: "non-Markdown write does not publish")
        unexpectedPublish.isInverted = true
        let counter = Counter()
        let indexer = MarkdownCorpusIndexer(fileURL: reader) { _ in
            counter.increment()
            if counter.value == 1 { initialPublished.fulfill() }
            else { unexpectedPublish.fulfill() }
        }
        indexer.start()
        await fulfillment(of: [initialPublished], timeout: 10)
        XCTAssertFalse(MarkdownCorpusIndexer.shouldRescan(relativePath: "output.txt", isDirectory: false))
        XCTAssertFalse(MarkdownCorpusIndexer.shouldRescan(relativePath: ".claude/cache.md", isDirectory: false))
        XCTAssertTrue(MarkdownCorpusIndexer.shouldRescan(relativePath: "docs/reader.md", isDirectory: false))
        XCTAssertTrue(MarkdownCorpusIndexer.shouldRescan(relativePath: ".lattice/ids.json", isDirectory: false))
        XCTAssertTrue(MarkdownCorpusIndexer.shouldRescan(relativePath: ".lattice/tasks/task_01KPP7QBZ3NJMXS4C9NA2XW01X.json", isDirectory: false))
        XCTAssertFalse(MarkdownCorpusIndexer.shouldRescan(relativePath: ".lattice/other.md", isDirectory: false))
        XCTAssertFalse(MarkdownCorpusIndexer.shouldRescan(relativePath: ".lattice/tasks/nested/task.json", isDirectory: false))
        try Data("not markdown".utf8).write(to: nonMarkdown)
        try Data("# ignored noise".utf8).write(to: ignoredMarkdown)
        await fulfillment(of: [unexpectedPublish], timeout: 1)
        _ = await scan(indexer)
        XCTAssertEqual(counter.value, 1, "unchanged rescans keep the same published revision")
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

    private func runGit(_ directory: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}
