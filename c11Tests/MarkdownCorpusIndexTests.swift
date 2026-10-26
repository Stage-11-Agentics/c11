import CoreServices
import Foundation
import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

private final class FakeFSEventStreamDriver: @unchecked Sendable {
    private final class Registration: @unchecked Sendable {
        let callback: FSEventStreamCallback
        let info: UnsafeMutableRawPointer
        let stream: FSEventStreamRef
        var dispatchQueue: DispatchQueue?
        var started = false

        init(callback: FSEventStreamCallback, info: UnsafeMutableRawPointer, stream: FSEventStreamRef) {
            self.callback = callback
            self.info = info
            self.stream = stream
        }
    }

    private struct PendingDelivery: @unchecked Sendable {
        let callback: FSEventStreamCallback
        let info: UnsafeMutableRawPointer
        let stream: FSEventStreamRef
        let dispatchQueue: DispatchQueue
        let paths: [String]
        let flags: [FSEventStreamEventFlags]
        let onConfiguredQueue: @Sendable () -> Void

        func deliver() {
            dispatchPrecondition(condition: .onQueue(dispatchQueue))
            onConfiguredQueue()
            let cfPaths = paths as CFArray
            let rawPaths = unsafeBitCast(cfPaths, to: UnsafeMutableRawPointer.self)
            let eventIDs = Array(repeating: FSEventStreamEventId(0), count: flags.count)
            flags.withUnsafeBufferPointer { flagsBuffer in
                eventIDs.withUnsafeBufferPointer { eventIDsBuffer in
                    callback(
                        stream,
                        info,
                        flags.count,
                        rawPaths,
                        flagsBuffer.baseAddress!,
                        eventIDsBuffer.baseAddress!
                    )
                }
            }
        }
    }

    private let lock = NSLock()
    private var registration: Registration?
    private var streamStorage: UnsafeMutableRawPointer?
    private var configuredQueueBeforeStart = false
    private var callbackDeliveredOnConfiguredQueue = false
    private let onStop: @Sendable () -> Void

    init(onStop: @escaping @Sendable () -> Void = {}) {
        self.onStop = onStop
    }

    var driver: MarkdownCorpusFSEventStreamDriver {
        MarkdownCorpusFSEventStreamDriver(
            create: { [self] callback, context, _ in
                guard let info = context.pointee.info else { return nil }
                let storage = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
                let stream = OpaquePointer(storage)
                let registration = Registration(callback: callback, info: info, stream: stream)
                lock.lock()
                self.registration = registration
                streamStorage = storage
                lock.unlock()
                return stream
            },
            setDispatchQueue: { [self] stream, queue in
                lock.lock()
                if let registration, registration.stream == stream {
                    registration.dispatchQueue = queue
                }
                lock.unlock()
            },
            start: { [self] stream in
                lock.lock()
                defer { lock.unlock() }
                guard let registration, registration.stream == stream,
                      registration.dispatchQueue != nil else { return false }
                configuredQueueBeforeStart = true
                registration.started = true
                return true
            },
            stop: { [self] _ in onStop() },
            invalidate: { _ in },
            release: { [self] _ in
                lock.lock()
                let storage = streamStorage
                streamStorage = nil
                registration = nil
                lock.unlock()
                storage?.deallocate()
            }
        )
    }

    var configuredQueueBeforeStartWasUsed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return configuredQueueBeforeStart
    }

    var callbackWasDeliveredOnConfiguredQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callbackDeliveredOnConfiguredQueue
    }

    func send(paths: [String], flags: [FSEventStreamEventFlags]) -> Bool {
        lock.lock()
        guard let registration, registration.started, let dispatchQueue = registration.dispatchQueue else {
            lock.unlock()
            return false
        }
        let delivery = PendingDelivery(
            callback: registration.callback,
            info: registration.info,
            stream: registration.stream,
            dispatchQueue: dispatchQueue,
            paths: paths,
            flags: flags,
            onConfiguredQueue: { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.callbackDeliveredOnConfiguredQueue = true
                self.lock.unlock()
            }
        )
        lock.unlock()
        dispatchQueue.async { delivery.deliver() }
        return true
    }
}

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

    func testNonGitFallbackCapsVisitedEntriesAndKeepsNearestNeighbors() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("plain", isDirectory: true)
        let lexicalNoise = root.appendingPathComponent("a-noise", isDirectory: true)
        let documentDirectory = root.appendingPathComponent("docs/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: lexicalNoise, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)

        let reader = documentDirectory.appendingPathComponent("reader.md")
        let nearby = documentDirectory.appendingPathComponent("nearby.md")
        try Data("# Reader\n".utf8).write(to: reader)
        try Data("# Nearby\n".utf8).write(to: nearby)
        for index in 0..<32 {
            try Data("# Noise \(index)\n".utf8)
                .write(to: lexicalNoise.appendingPathComponent("\(index).md"))
        }

        let maximumVisitedEntries = 5
        let walk = MarkdownCorpusIndexer.walkedPaths(
            rootURL: root,
            priorityRelativePaths: ["docs/nested/reader.md"],
            maximumVisitedEntries: maximumVisitedEntries
        )
        XCTAssertLessThanOrEqual(walk.visitedEntries, maximumVisitedEntries)
        XCTAssertTrue(walk.truncated)
        XCTAssertTrue(walk.paths.contains("docs/nested/reader.md"))
        XCTAssertTrue(walk.paths.contains("docs/nested/nearby.md"))

        var limits = MarkdownCorpusIndexer.Limits()
        limits.maximumVisitedEntries = maximumVisitedEntries
        let snapshot = await scan(MarkdownCorpusIndexer(
            rootURL: root,
            limits: limits,
            priorityFileURLs: [reader]
        ) { _ in })
        XCTAssertEqual(Set(snapshot.documents.map(\.relativePath)), Set(["docs/nested/reader.md", "docs/nested/nearby.md"]))
        XCTAssertTrue(snapshot.truncated)
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

    func testHostileHeadingsAreCappedBeforeRegexProcessing() throws {
        let root = URL(fileURLWithPath: "/tmp/markdown-hostile-heading-fixture", isDirectory: true)
        let file = root.appendingPathComponent("reader.md")
        let bracketHeading = "# " + String(repeating: "[", count: 16_385)
        let setextHeading = String(repeating: "<", count: 16_385)
        let backtickHeading = "# " + String(repeating: "`", count: 16_385)
        let combiningHeading = "# " + String(repeating: "<\u{301}", count: 4_096)
        let source = [
            bracketHeading,
            setextHeading,
            "===",
            backtickHeading,
            combiningHeading,
            "## **Bold** `code` [link](x.md)",
        ].joined(separator: "\n")

        let parsed = MarkdownCorpusParser.parse(
            source,
            fileURL: file,
            rootURL: root,
            maximumHeadings: 20,
            maximumLinks: 20,
            maximumTicketIDs: 20
        )
        XCTAssertEqual(parsed.document.headings.map(\.line), [1, 2, 5, 6])
        XCTAssertFalse(parsed.document.headings.contains { $0.line == 4 }, "a heading that strips to empty is dropped")
        XCTAssertTrue(parsed.document.headings.allSatisfy { $0.text.unicodeScalars.count <= 512 })
        XCTAssertEqual(parsed.document.headings[0].text, String(repeating: "[", count: 512))
        XCTAssertEqual(parsed.document.headings[1].text, String(repeating: "<", count: 512))
        XCTAssertEqual(parsed.document.headings[2].text.unicodeScalars.count, 512)
        XCTAssertEqual(parsed.document.headings.last?.text, "Bold code link")
        XCTAssertEqual(parsed.document.headings.last?.slug, "bold-code-link")
    }

    func testEmptyHeadingsAreBoundedByTheHeadingAttemptLimit() throws {
        let root = URL(fileURLWithPath: "/tmp/markdown-empty-heading-budget-fixture", isDirectory: true)
        let file = root.appendingPathComponent("reader.md")
        let emptyHeading = "# " + String(repeating: "`", count: 512)
        let source = Array(repeating: emptyHeading, count: 3_000).joined(separator: "\n")
        let maximumHeadings = 128

        let parsed = MarkdownCorpusParser.parse(
            source,
            fileURL: file,
            rootURL: root,
            maximumHeadings: maximumHeadings,
            maximumLinks: 20,
            maximumTicketIDs: 20
        )

        XCTAssertEqual(parsed.headingTextAttempts, maximumHeadings * 2)
        XCTAssertTrue(parsed.document.headings.isEmpty)
        XCTAssertFalse(parsed.headingsTruncated, "the work cap must not trigger repeated cache reparses")
    }

    func testEmptyHeadingAttemptsConsumeTheCorpusBudgetAndRemainCached() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let firstFile = root.appendingPathComponent("a.md")
        let laterFile = root.appendingPathComponent("b.md")
        let emptyHeading = "# " + String(repeating: "`", count: 512)
        try Data(Array(repeating: emptyHeading, count: 300).joined(separator: "\n").utf8).write(to: firstFile)
        try Data("# Later heading\n".utf8).write(to: laterFile)
        var limits = MarkdownCorpusIndexer.Limits()
        limits.maximumTotalHeadings = 128
        let indexer = MarkdownCorpusIndexer(fileURL: firstFile, limits: limits) { _ in }

        let first = await scan(indexer)
        XCTAssertTrue(first.truncated)
        XCTAssertTrue(first.documents.first(where: { $0.relativePath == "b.md" })?.headings.isEmpty == true)
        XCTAssertEqual(first.filesReparsed, 2)

        let unchanged = await scan(indexer)
        XCTAssertTrue(unchanged.documents.first(where: { $0.relativePath == "b.md" })?.headings.isEmpty == true)
        XCTAssertEqual(unchanged.filesReparsed, 2, "cached heading attempts must consume the corpus budget without reparsing")
        indexer.stop()
    }

    func testLinkPatternWorkBudgetBoundsManyAdversarialLines() throws {
        let root = URL(fileURLWithPath: "/tmp/markdown-link-budget-fixture", isDirectory: true)
        let file = root.appendingPathComponent("reader.md")
        let hostileLine = String(repeating: "[", count: 16_000)
        let source = Array(repeating: hostileLine, count: 64).joined(separator: "\n")

        let parsed = MarkdownCorpusParser.parse(
            source,
            fileURL: file,
            rootURL: root,
            maximumHeadings: 20,
            maximumLinks: 20,
            maximumTicketIDs: 20
        )
        XCTAssertTrue(parsed.document.links.isEmpty)
        XCTAssertTrue(parsed.linksTruncated, "the per-document work budget should report skipped link extraction")

        let ordinary = MarkdownCorpusParser.parse(
            "See [target](target.md)",
            fileURL: file,
            rootURL: root,
            maximumHeadings: 20,
            maximumLinks: 20,
            maximumTicketIDs: 20
        )
        XCTAssertEqual(ordinary.document.links.map(\.text), ["target"])
    }

    func testScaledLinkBudgetSkipsOnlyOverBudgetLinesAndKeepsOrdinaryLinks() throws {
        let root = URL(fileURLWithPath: "/tmp/markdown-scaled-link-budget-fixture", isDirectory: true)
        let file = root.appendingPathComponent("reader.md")
        let expensiveLine = String(repeating: "[a](<", count: 1_264)
        let oldBudgetWork = expensiveLine.filter { $0 == "[" }.count * expensiveLine.utf8.count
        XCTAssertLessThan(expensiveLine.utf8.count, 16 * 1024)
        XCTAssertLessThan(oldBudgetWork, 8_000_000)

        let parsed = MarkdownCorpusParser.parse(
            "Before [first](first.md)\n\(expensiveLine)\nAfter [second](second.md)",
            fileURL: file,
            rootURL: root,
            maximumHeadings: 20,
            maximumLinks: 20,
            maximumTicketIDs: 20
        )
        XCTAssertTrue(parsed.linksTruncated, "the proportional budget should reject the formerly under-budget line")
        XCTAssertEqual(parsed.document.links.map(\.text), ["first", "second"], "later lines should still be scanned")

        let normalLines = Array(repeating: "Release notes [setup](setup.md) and [install](install.md).", count: 2_000)
        let normalSource = normalLines.joined(separator: "\n")
        let normal = MarkdownCorpusParser.parse(
            normalSource,
            fileURL: file,
            rootURL: root,
            maximumHeadings: 20,
            maximumLinks: 4_000,
            maximumTicketIDs: 20
        )
        XCTAssertEqual(normal.document.links.count, 4_000)
        XCTAssertFalse(normal.linksTruncated)
    }

    func testExternalLinksOnEarlierLinesDoNotHideLaterMarkdownLinks() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("changelog.md")
        let externalLines = (0..<200).map { "- [PR \($0)](https://example.com/pull/\($0))" }
        let parsed = MarkdownCorpusParser.parse(
            (externalLines + ["See [target](target.md)."]).joined(separator: "\n"),
            fileURL: file,
            rootURL: root,
            maximumHeadings: 20,
            maximumLinks: 20,
            maximumTicketIDs: 20
        )
        XCTAssertEqual(parsed.document.links.map(\.text), ["target"])
        XCTAssertFalse(parsed.linksTruncated)
    }

    func testManyExternalLinksDoNotReparseCachedMarkdownOnUnchangedRescan() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let reader = root.appendingPathComponent("CHANGELOG.md")
        let externalLines = (0..<200).map { "- [PR \($0)](https://example.com/pull/\($0))" }
        try Data((externalLines + ["See [target](target.md).\n"]).joined(separator: "\n").utf8).write(to: reader)
        let indexer = MarkdownCorpusIndexer(fileURL: reader) { _ in }

        let first = await scan(indexer)
        XCTAssertEqual(first.documents.first?.links.map(\.text), ["target"])
        XCTAssertEqual(first.filesReparsed, 1)

        let unchanged = await scan(indexer)
        let filesReparsedOnRescan = unchanged.filesReparsed - first.filesReparsed
        XCTAssertEqual(filesReparsedOnRescan, 0, "filesReparsed is cumulative; an unchanged rescan should add zero")
        indexer.stop()
    }

    func testBudgetTruncatedLinksAreReusedOnUnchangedRescan() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let reader = root.appendingPathComponent("reader.md")
        let expensiveLine = String(repeating: "[a](<", count: 1_264)
        try Data("[before](before.md)\n\(expensiveLine)\n[after](after.md)\n".utf8).write(to: reader)
        let indexer = MarkdownCorpusIndexer(fileURL: reader) { _ in }

        let first = await scan(indexer)
        XCTAssertTrue(first.truncated)
        XCTAssertEqual(first.documents.first?.links.map(\.text), ["before", "after"])
        XCTAssertEqual(first.filesReparsed, 1)

        let unchanged = await scan(indexer)
        XCTAssertTrue(unchanged.truncated)
        XCTAssertEqual(unchanged.filesReparsed, 1, "budget truncation alone must not trigger another parse")
        indexer.stop()
    }

    func testCacheReparsesWhenLinkSlotsExpand() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let firstFile = root.appendingPathComponent("a.md")
        let secondFile = root.appendingPathComponent("b.md")
        try Data("[one](one.md)\n[two](two.md)\n".utf8).write(to: firstFile)
        try Data("[alpha](alpha.md)\n[beta](beta.md)\n".utf8).write(to: secondFile)
        var limits = MarkdownCorpusIndexer.Limits()
        limits.maximumTotalLinks = 2
        let indexer = MarkdownCorpusIndexer(fileURL: firstFile, limits: limits) { _ in }

        let initiallyCapped = await scan(indexer)
        XCTAssertEqual(initiallyCapped.documents.first(where: { $0.relativePath == "b.md" })?.links.count, 0)
        XCTAssertEqual(initiallyCapped.filesReparsed, 2)

        try Data("No links now\n".utf8).write(to: firstFile)
        let expanded = await scan(indexer)
        XCTAssertEqual(expanded.documents.first(where: { $0.relativePath == "b.md" })?.links.count, 2)
        XCTAssertEqual(expanded.filesReparsed, 4, "slot-truncated cached content should be reparsed when its allocation grows")
        indexer.stop()
    }

    func testTicketMatchingStaysLinearWithManyConfiguredPrefixes() throws {
        let root = URL(fileURLWithPath: "/tmp/markdown-ticket-prefix-fixture", isDirectory: true)
        let file = root.appendingPathComponent("reader.md")
        var prefixes = Set((0..<50_000).map { "P\($0)" })
        prefixes.insert("C11")
        let longestUnusualPrefix = "Z9Y8X7W6V5U4T3SR"
        prefixes.insert(longestUnusualPrefix)

        let parsed = MarkdownCorpusParser.parse(
            "C11-5 XC11-6 C11-7x \(longestUnusualPrefix)-123456789",
            fileURL: file,
            rootURL: root,
            maximumHeadings: 20,
            maximumLinks: 20,
            maximumTicketIDs: 20,
            ticketPrefixes: prefixes
        )
        XCTAssertEqual(parsed.document.ticketIDs, ["C11-5", "\(longestUnusualPrefix)-123456789"])
    }

    func testStopCancelsInFlightScanAndFreshIndexerCanUseSameRoot() async throws {
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
        let reader = root.appendingPathComponent("reader.md")
        let second = root.appendingPathComponent("second.md")
        try Data("# Reader\n".utf8).write(to: reader)
        try Data("# Second\n".utf8).write(to: second)

        let firstCandidateIndexed = DispatchSemaphore(value: 0)
        let resumeScan = DispatchSemaphore(value: 0)
        let stoppedCandidateCount = Counter()
        let stoppedPublishes = Counter()
        let stoppedIndexer = MarkdownCorpusIndexer(
            rootURL: root,
            priorityFileURLs: [reader],
            afterCandidateIndexed: { _ in
                stoppedCandidateCount.increment()
                if stoppedCandidateCount.value == 1 {
                    firstCandidateIndexed.signal()
                    _ = resumeScan.wait(timeout: .now() + 10)
                }
            }
        ) { _ in stoppedPublishes.increment() }
        stoppedIndexer.start()
        let reachedFirstCandidate = firstCandidateIndexed.wait(timeout: .now() + 30)
        stoppedIndexer.stop()
        resumeScan.signal()
        XCTAssertEqual(reachedFirstCandidate, .success)
        let stoppedSnapshot = await scan(stoppedIndexer)
        XCTAssertTrue(stoppedSnapshot.documents.isEmpty)
        XCTAssertEqual(stoppedCandidateCount.value, 1, "stop should halt before the next file is parsed")
        XCTAssertEqual(stoppedPublishes.value, 0)

        let restartedPublishes = Counter()
        let restartedIndexer = MarkdownCorpusIndexer(rootURL: root, priorityFileURLs: [reader]) { _ in
            restartedPublishes.increment()
        }
        let restartedSnapshot = await scan(restartedIndexer)
        XCTAssertEqual(Set(restartedSnapshot.documents.map(\.relativePath)), Set(["reader.md", "second.md"]))
        XCTAssertEqual(restartedPublishes.value, 1)
        restartedIndexer.stop()
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

    func testFSEventCallbackRefreshesAddAndDeleteMarkdown() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let initial = root.appendingPathComponent("reader.md")
        let added = root.appendingPathComponent("added.md")
        try Data("# Reader".utf8).write(to: initial)

        let streamStopped = expectation(description: "FSEvent stream is stopped during teardown")
        let driver = FakeFSEventStreamDriver(onStop: { streamStopped.fulfill() })
        let initialPublished = expectation(description: "initial snapshot after stream start")
        let streamStarted = expectation(description: "stream starts after its dispatch queue is configured")
        let appeared = expectation(description: "FSEvent callback indexes the added document")
        let disappeared = expectation(description: "FSEvent callback removes the deleted document")
        let indexer = MarkdownCorpusIndexer(
            rootURL: root,
            priorityFileURLs: [initial],
            streamDriver: driver.driver
        ) { snapshot in
            if snapshot.revision == 1 { initialPublished.fulfill() }
            if snapshot.containsDocument(path: added.path) { appeared.fulfill() }
            if snapshot.revision > 1 && !snapshot.containsDocument(path: added.path) { disappeared.fulfill() }
        }
        indexer.start { started in
            if started { streamStarted.fulfill() }
        }
        await fulfillment(of: [initialPublished, streamStarted], timeout: 5)
        XCTAssertTrue(driver.configuredQueueBeforeStartWasUsed)

        try Data("# Added".utf8).write(to: added)
        XCTAssertTrue(driver.send(
            paths: [added.path],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)]
        ))
        await fulfillment(of: [appeared], timeout: 10)

        try FileManager.default.removeItem(at: added)
        XCTAssertTrue(driver.send(
            paths: [added.path],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)]
        ))
        await fulfillment(of: [disappeared], timeout: 10)
        XCTAssertTrue(driver.callbackWasDeliveredOnConfiguredQueue)
        indexer.stop()
        await fulfillment(of: [streamStopped], timeout: 5)
    }

    func testDroppedFSEventSkipsMustScanUnderSkippedSubtreeButRescansOnUserOrKernelDrop() async throws {
        let cases: [(name: String, relativePath: String, flag: FSEventStreamEventFlags, shouldRescan: Bool)] = [
            ("MustScanSubDirs in skipped subtree", "node_modules", FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), false),
            ("MustScanSubDirs in indexed subtree", "docs", FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), true),
            ("UserDropped in skipped subtree", "node_modules", FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped), true),
            ("KernelDropped in skipped subtree", "node_modules", FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped), true),
        ]

        for (index, testCase) in cases.enumerated() {
            let temp = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let root = temp.appendingPathComponent("repo", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let eventDirectory = root.appendingPathComponent(testCase.relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: eventDirectory, withIntermediateDirectories: true)
            let initial = root.appendingPathComponent("reader.md")
            let added = root.appendingPathComponent("added-\(index).md")
            let eventPath = eventDirectory.appendingPathComponent("dependency.md")
            try Data("# Reader".utf8).write(to: initial)
            try Data("# Dependency".utf8).write(to: eventPath)

            let driver = FakeFSEventStreamDriver()
            let initialPublished = expectation(description: "initial snapshot: \(testCase.name)")
            let streamStarted = expectation(description: "fake stream starts: \(testCase.name)")
            let appeared = expectation(description: "expected rescan after \(testCase.name)")
            appeared.isInverted = !testCase.shouldRescan
            let indexer = MarkdownCorpusIndexer(
                rootURL: root,
                priorityFileURLs: [initial],
                streamDriver: driver.driver
            ) { snapshot in
                if snapshot.revision == 1 { initialPublished.fulfill() }
                if snapshot.containsDocument(path: added.path) { appeared.fulfill() }
            }
            indexer.start { started in
                if started { streamStarted.fulfill() }
            }
            await fulfillment(of: [initialPublished, streamStarted], timeout: 5)
            try Data("# Added".utf8).write(to: added)

            XCTAssertTrue(driver.send(
                paths: [eventDirectory.path],
                flags: [testCase.flag]
            ))
            if testCase.shouldRescan {
                await fulfillment(of: [appeared], timeout: 2)
            } else {
                await fulfillment(of: [appeared], timeout: 1)
            }
            indexer.stop()
        }
    }

    func testLiveFSEventsStreamRefreshesAddedMarkdown() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep this small root outside Git so repository metadata writes do
        // not compete with the live Markdown event under test.
        let initial = root.appendingPathComponent("reader.md")
        let added = root.appendingPathComponent("added.md")
        try Data("# Reader".utf8).write(to: initial)

        let initialSnapshotPublished = expectation(description: "initial live-stream scan completes")
        let streamStarted = expectation(description: "real FSEvents stream starts")
        let addedSnapshotPublished = expectation(description: "real FSEvents delivery indexes the added document")
        let indexer = MarkdownCorpusIndexer(fileURL: initial) { snapshot in
            if snapshot.revision == 1 { initialSnapshotPublished.fulfill() }
            if snapshot.containsDocument(path: added.path) { addedSnapshotPublished.fulfill() }
        }
        indexer.start { started in
            if started { streamStarted.fulfill() }
        }
        await fulfillment(of: [initialSnapshotPublished, streamStarted], timeout: 15)
        try Data("# Added\n".utf8).write(to: added)
        await fulfillment(of: [addedSnapshotPublished], timeout: 30)
        indexer.stop()
    }

    func testIgnoreCheckSurvivesGitExitingBeforeReadingALargeEventBatch() throws {
        // `.git` here is an empty directory, so `git check-ignore --stdin` exits
        // without reading. Event paths larger than the 64 KB pipe buffer block
        // the stdin write until git exits, so the write fails with EPIPE every
        // time. That must report "nothing ignored", not take the process down.
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let initial = root.appendingPathComponent("reader.md")
        try Data("# Reader".utf8).write(to: initial)
        let directory = root.resolvingSymlinksInPath().appendingPathComponent(String(repeating: "b", count: 200))
        let stem = String(repeating: "n", count: 200)
        let paths = (0..<800).map { directory.appendingPathComponent("\(stem)-\($0).md").path }
        XCTAssertGreaterThan(paths.reduce(0) { $0 + $1.utf8.count }, 256 * 1024)

        let indexer = MarkdownCorpusIndexer(fileURL: initial) { _ in }
        XCTAssertEqual(indexer.ignoredEventPaths(paths), [])
    }

    func testRepositoryConfigCannotRunCommandsWhenTheIndexListsOrChecksIgnores() async throws {
        // A hostile `.git/config` (an extracted archive can ship one) names two
        // programs git starts on its own during read-only listing: an fsmonitor
        // hook, run on every index read, and an `ext::` transport, run by a lazy
        // fetch for the missing blob of a skip-worktree `.gitignore` in a
        // partial clone. Each writes a marker file when it runs.
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        let elsewhere = temp.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ignored"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("# Reader\n".utf8).write(to: root.appendingPathComponent("reader.md"))
        try Data("ignored/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("hidden.md\n".utf8).write(to: root.appendingPathComponent("sub/.gitignore"))
        let commit = ["-c", "user.name=c11", "-c", "user.email=c11@example.invalid", "-c", "commit.gpgsign=false"]
        try runGit(root, ["init", "-q"])
        try runGit(root, ["add", "-A"])
        try runGit(root, commit + ["commit", "-q", "--no-verify", "-m", "init"])
        let blob = try gitOutput(root, ["rev-parse", "HEAD:sub/.gitignore"])
        try runGit(root, ["update-index", "--skip-worktree", "sub/.gitignore"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("sub/.gitignore"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(
            ".git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))"
        ))
        try runGit(root, ["config", "core.repositoryformatversion", "1"])
        try Data("# Untracked\n".utf8).write(to: root.appendingPathComponent("docs/untracked.md"))
        try Data("# Noise\n".utf8).write(to: root.appendingPathComponent("ignored/noise.md"))
        try Data("# Hidden\n".utf8).write(to: root.appendingPathComponent("sub/hidden.md"))

        let fsmonitorMarker = temp.appendingPathComponent("fsmonitor-ran")
        let transportMarker = temp.appendingPathComponent("transport-ran")
        let fsmonitor = try markerScript(temp.appendingPathComponent("fsmonitor.sh"), touching: fsmonitorMarker)
        let transport = try markerScript(temp.appendingPathComponent("transport.sh"), touching: transportMarker)
        // `protocol.ext.allow` outranks a command-line `protocol.allow=never`.
        try appendConfig(root, """
        [core]
        \tfsmonitor = \(fsmonitor.path)
        \tuntrackedCache = true
        [protocol "ext"]
        \tallow = always
        [remote "origin"]
        \turl = ext::\(transport.path) %S
        \tpromisor = true
        [extensions]
        \tpartialClone = origin

        """)

        // The fixture is live: plain git runs both programs.
        _ = try? gitOutput(root, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fsmonitorMarker.path), "fixture: fsmonitor hook should run under plain git")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transportMarker.path), "fixture: lazy fetch should run the ext:: transport under plain git")
        try? FileManager.default.removeItem(at: fsmonitorMarker)
        try? FileManager.default.removeItem(at: transportMarker)

        // core.worktree would move the listing and the ignore rules elsewhere.
        try appendConfig(root, "[core]\n\tworktree = \(elsewhere.path)\n")

        let reader = root.appendingPathComponent("reader.md")
        let indexer = MarkdownCorpusIndexer(fileURL: reader) { _ in }
        let snapshot = await scan(indexer)
        let listed = Set(snapshot.documents.map(\.relativePath))
        XCTAssertTrue(listed.isSuperset(of: ["reader.md", "docs/untracked.md"]), "listed: \(listed.sorted())")
        XCTAssertFalse(listed.contains("ignored/noise.md"), "the listing comes from git, which honors .gitignore; the fallback walk does not")

        let canonicalRoot = indexer.rootURL
        let noise = canonicalRoot.appendingPathComponent("ignored/noise.md").path
        let ignored = indexer.ignoredEventPaths([
            noise,
            canonicalRoot.appendingPathComponent("reader.md").path,
            canonicalRoot.appendingPathComponent("sub/hidden.md").path,
        ])
        XCTAssertEqual(ignored, [noise])

        XCTAssertFalse(FileManager.default.fileExists(atPath: fsmonitorMarker.path), "repository core.fsmonitor ran")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transportMarker.path), "repository promisor remote ran its transport")
        indexer.stop()

        // Git without the GIT_NO_LAZY_FETCH backport still starts the fetch.
        // GIT_ALLOW_PROTOCOL alone must stop the transport there; without it,
        // the transport runs.
        func listWithoutLazyFetchGuard(keepingProtocolAllowList: Bool) throws {
            let process = UntrustedRepositoryGit.process(in: canonicalRoot, arguments: [
                "ls-files", "--cached", "--others", "--exclude-standard", "-z"
            ])
            process.environment?["GIT_NO_LAZY_FETCH"] = "0"
            if !keepingProtocolAllowList { process.environment?["GIT_ALLOW_PROTOCOL"] = nil }
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        try listWithoutLazyFetchGuard(keepingProtocolAllowList: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transportMarker.path), "GIT_ALLOW_PROTOCOL did not stop the lazy-fetch transport")
        try listWithoutLazyFetchGuard(keepingProtocolAllowList: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transportMarker.path), "fixture: without both guards the transport should run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fsmonitorMarker.path), "repository core.fsmonitor ran")
    }

    func testGitBlockedOnAFIFOIsKilledAtTheTimeout() throws {
        // A FIFO named .gitignore blocks git's read until a writer appears.
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(root, ["init", "-q"])
        try Data("# Reader\n".utf8).write(to: root.appendingPathComponent("reader.md"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent(".gitignore").path, 0o644), 0)

        let started = Date()
        let result = UntrustedRepositoryGit.run(
            in: root.resolvingSymlinksInPath(),
            arguments: ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            timeout: 1
        )
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testIgnoreCheckSkipsPathsGitWouldReadAsPathspecMagic() throws {
        // `check-ignore --stdin` parses a leading `:` as pathspec magic and
        // fails the whole batch; one such filename must not hide the others.
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ignored"), withIntermediateDirectories: true)
        try runGit(root, ["init", "-q"])
        try Data("ignored/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let reader = root.appendingPathComponent("reader.md")
        try Data("# Reader\n".utf8).write(to: reader)

        let indexer = MarkdownCorpusIndexer(fileURL: reader) { _ in }
        let canonicalRoot = indexer.rootURL
        let noise = canonicalRoot.appendingPathComponent("ignored/noise.md").path
        let ignored = indexer.ignoredEventPaths([
            canonicalRoot.appendingPathComponent(":(glob)odd.md").path,
            noise,
        ])
        XCTAssertEqual(ignored, [noise])
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

    private func gitOutput(_ directory: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendConfig(_ repository: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: repository.appendingPathComponent(".git/config"))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func markerScript(_ script: URL, touching marker: URL) throws -> URL {
        try Data("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
