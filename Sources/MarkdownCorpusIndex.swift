import CoreServices
import Darwin
import Foundation

struct MarkdownCorpusHeading: Equatable, Sendable {
    let level: Int
    let text: String
    let slug: String
    let line: Int
}

struct MarkdownCorpusDocument: Equatable, Sendable {
    let path: String
    let relativePath: String
    let title: String
    let headings: [MarkdownCorpusHeading]
    let links: [MarkdownCorpusLink]
    let ticketIDs: [String]
}

struct MarkdownCorpusLink: Equatable, Sendable {
    let sourcePath: String
    let sourceTitle: String
    let sourceSection: String?
    let sourceSectionSlug: String?
    let line: Int
    let text: String
    let targetPath: String
    let targetFragment: String?
}

struct MarkdownTicketCard: Equatable, Sendable {
    let title: String
    let status: String
}

struct MarkdownCorpusSnapshot: Equatable, Sendable {
    let rootPath: String?
    let documents: [MarkdownCorpusDocument]
    let links: [MarkdownCorpusLink]
    let tickets: [String: MarkdownTicketCard]
    let truncated: Bool
    let revision: Int
    let filesReparsed: Int
    /// Encoded on the indexer's utility queue so the main actor only submits a
    /// single immutable string to WebKit.
    let bridgeJSON: String

    init(
        rootPath: String?,
        documents: [MarkdownCorpusDocument],
        links: [MarkdownCorpusLink],
        tickets: [String: MarkdownTicketCard],
        truncated: Bool,
        revision: Int,
        filesReparsed: Int,
        bridgeJSON precomputedBridgeJSON: String? = nil
    ) {
        self.rootPath = rootPath
        self.documents = documents
        self.links = links
        self.tickets = tickets
        self.truncated = truncated
        self.revision = revision
        self.filesReparsed = filesReparsed
        bridgeJSON = precomputedBridgeJSON ?? Self.encodeBridgeValue(
            rootPath: rootPath,
            documents: documents,
            links: links,
            tickets: tickets,
            truncated: truncated,
            revision: revision
        )
    }

    static let empty = MarkdownCorpusSnapshot(
        rootPath: nil,
        documents: [],
        links: [],
        tickets: [:],
        truncated: false,
        revision: 0,
        filesReparsed: 0
    )

    func containsDocument(path: String) -> Bool {
        documents.contains { $0.path == path }
    }

    func backlinks(to path: String, fragment: String? = nil) -> [MarkdownCorpusLink] {
        let resolvedPath = Self.resolvedPath(path)
        return links.filter { link in
            guard Self.resolvedPath(link.targetPath) == resolvedPath else { return false }
            guard let fragment, !fragment.isEmpty else { return true }
            return link.targetFragment?.caseInsensitiveCompare(fragment) == .orderedSame
        }
    }

    func validatesNavigation(
        path: String,
        fragment: String?,
        origin: MarkdownNavigationOrigin,
        currentPath: String?
    ) -> Bool {
        let targetPath = Self.standardizedPath(path)
        guard let document = documents.first(where: { Self.standardizedPath($0.path) == targetPath }) else { return false }
        if let fragment, !fragment.isEmpty,
           !document.headings.contains(where: { $0.slug == fragment }) { return false }
        guard origin == .backlink else { return origin == .palette }
        guard let currentPath else { return false }
        let resolvedCurrent = Self.standardizedPath(currentPath)
        return links.contains {
            Self.standardizedPath($0.sourcePath) == targetPath
                && Self.standardizedPath($0.targetPath) == resolvedCurrent
                && $0.sourceSectionSlug == (fragment?.isEmpty == true ? nil : fragment)
        }
    }

    static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func encodeBridgeValue(
        rootPath: String?,
        documents: [MarkdownCorpusDocument],
        links: [MarkdownCorpusLink],
        tickets: [String: MarkdownTicketCard],
        truncated: Bool,
        revision: Int
    ) -> String {
        let documentValues: [[String: Any]] = documents.map { document in
            [
                "path": document.path,
                "relative_path": document.relativePath,
                "title": document.title,
                "headings": document.headings.map { heading in
                    ["level": heading.level, "text": heading.text, "slug": heading.slug, "line": heading.line]
                }
            ]
        }
        let linkValues: [[String: Any]] = links.map { link in
            [
                "source": link.sourcePath,
                "source_title": link.sourceTitle,
                "section": link.sourceSection as Any? ?? NSNull(),
                "section_slug": link.sourceSectionSlug as Any? ?? NSNull(),
                "line": link.line,
                "text": link.text,
                "target": link.targetPath,
                "fragment": link.targetFragment as Any? ?? NSNull()
            ]
        }
        let ticketValues = tickets.mapValues { ["title": $0.title, "status": $0.status] }
        let value: [String: Any] = [
            "root": rootPath as Any? ?? NSNull(),
            "current": NSNull(),
            "documents": documentValues,
            "links": linkValues,
            "tickets": ticketValues,
            "truncated": truncated,
            "revision": revision
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

/// A bounded, root-shared Markdown corpus. Directory discovery and every read
/// happen on its utility queue; renderer callbacks only receive immutable
/// snapshots. FSEvents drives refreshes and unchanged files reuse parsed data.
final class MarkdownCorpusIndexer: @unchecked Sendable {
    struct Limits: Equatable, Sendable {
        var maximumDocuments = 5_000
        var maximumVisitedEntries = 50_000
        var maximumFileBytes = 1_048_576
        var maximumTotalBytes = 67_108_864
        var maximumHeadingsPerDocument = 128
        var maximumTotalHeadings = 20_000
        var maximumLinksPerDocument = 128
        var maximumTotalLinks = 20_000
        var maximumTicketIDsPerDocument = 256
        var maximumTotalTicketIDs = 5_000
        var maximumBoardBytes = 4_194_304
        var maximumBoardLookupBytes = 8_388_608
    }

    private static let skippedDirectoryNames: Set<String> = [
        ".git", ".claude", ".lattice", ".build", ".next", ".swiftpm",
        "node_modules", "DerivedData", "build", "build-remote", "build-test-local",
        "dist", "target", "c11-worktrees", ".venv", "venv"
    ]

    private struct Signature: Equatable {
        let size: Int
        let modified: TimeInterval
        let resourceIdentifier: String
    }

    private struct IndexedFile {
        let signature: Signature
        let document: MarkdownCorpusDocument
        let linkSlotsUsed: Int
        let headingsTruncated: Bool
        let linksTruncated: Bool
        let ticketIDsTruncated: Bool
    }

    private struct BoardIndex {
        let tasksByTicket: [String: String]
        let prefixes: Set<String>
    }

    let rootURL: URL
    private let rootAccess: MarkdownAssetRoot?
    private let queue = DispatchQueue(label: "com.stage11.c11.markdown-corpus", qos: .utility)
    private let limits: Limits
    private let onUpdate: @Sendable (MarkdownCorpusSnapshot) -> Void
    private var stream: FSEventStreamRef?
    private var indexedFiles: [String: IndexedFile] = [:]
    private var snapshotValue = MarkdownCorpusSnapshot.empty
    private var priorityRelativePaths: [String]
    private var revision = 0
    private var filesReparsed = 0
    private var scanQueued = false
    private var stopped = false

    init(
        rootURL: URL,
        limits: Limits = Limits(),
        priorityFileURLs: [URL] = [],
        onUpdate: @escaping @Sendable (MarkdownCorpusSnapshot) -> Void
    ) {
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        self.rootURL = canonicalRoot
        rootAccess = MarkdownAssetRoot(directory: canonicalRoot)
        self.limits = limits
        self.onUpdate = onUpdate
        priorityRelativePaths = Self.relativePaths(for: priorityFileURLs, under: canonicalRoot)
    }

    convenience init(
        fileURL: URL,
        limits: Limits = Limits(),
        onUpdate: @escaping @Sendable (MarkdownCorpusSnapshot) -> Void
    ) {
        self.init(rootURL: Self.corpusRoot(for: fileURL), limits: limits, priorityFileURLs: [fileURL], onUpdate: onUpdate)
    }

    static func corpusRoot(for fileURL: URL) -> URL {
        MarkdownDocumentRoot.corpusRoot(for: fileURL)
    }

    func updatePriorityFiles(_ fileURLs: [URL]) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let paths = Self.relativePaths(for: fileURLs, under: self.rootURL)
            guard paths != self.priorityRelativePaths else { return }
            self.priorityRelativePaths = paths
            self.scanAndPublish()
        }
    }

    private static func relativePaths(for fileURLs: [URL], under rootURL: URL) -> [String] {
        let rootPath = rootURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var seen: Set<String> = []
        return fileURLs.compactMap { fileURL in
            let path = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(prefix) else { return nil }
            let relative = String(path.dropFirst(prefix.count))
            guard !relative.isEmpty, seen.insert(relative).inserted else { return nil }
            return relative
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.startWatcherOnQueue()
            self.scanAndPublish()
        }
    }

    func refreshNow(completion: (@Sendable (MarkdownCorpusSnapshot) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.scanAndPublish()
            if let completion { completion(self.snapshotValue) }
        }
    }

    func currentSnapshot(completion: @escaping @Sendable (MarkdownCorpusSnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self else { completion(.empty); return }
            completion(self.snapshotValue)
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            stopWatcherOnQueue()
            indexedFiles.removeAll(keepingCapacity: false)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func scheduleRescan(for paths: [String], eventFlags: [FSEventStreamEventFlags]) {
        queue.async { [weak self] in
            guard let self, !self.stopped, !self.scanQueued else { return }
            let events = paths.enumerated().compactMap { index, path -> (String, Bool)? in
                let flags: FSEventStreamEventFlags = index < eventFlags.count ? eventFlags[index] : 0
                let integerFlags = Int(flags)
                let canonicalPath = Self.resolvedPathAllowingMissingTail(path)
                let isDirectory = integerFlags & kFSEventStreamEventFlagItemIsDir != 0
                    || (canonicalPath == self.rootURL.path
                        && integerFlags & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0)
                return self.isRelevantFileEvent(canonicalPath, isDirectory: isDirectory) ? (canonicalPath, isDirectory) : nil
            }
            guard !events.isEmpty else { return }
            let ignored = self.ignoredEventPaths(events.map(\.0))
            let rootPrefix = self.rootURL.path.hasSuffix("/") ? self.rootURL.path : self.rootURL.path + "/"
            guard events.contains(where: { event in
                let relative = event.0.hasPrefix(rootPrefix) ? String(event.0.dropFirst(rootPrefix.count)) : ""
                return Self.isBoardEventPath(relative, isDirectory: event.1) || !ignored.contains(event.0)
            }) else { return }
            self.scanQueued = true
            self.queue.async { [weak self] in
                guard let self else { return }
                self.scanQueued = false
                guard !self.stopped else { return }
                self.scanAndPublish()
            }
        }
    }

    private func startWatcherOnQueue() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, rawPaths, eventFlags, _ in
            guard let info else { return }
            let indexer = Unmanaged<MarkdownCorpusIndexer>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = unsafeBitCast(rawPaths, to: CFArray.self)
            let paths = (cfPaths as NSArray).compactMap { $0 as? String }
            let flags = (0..<eventCount).map { index in eventFlags[index] }
            indexer.scheduleRescan(for: paths, eventFlags: flags)
        }
        let paths = [rootURL.path] as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            UInt64(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    private func isRelevantFileEvent(_ eventPath: String, isDirectory: Bool) -> Bool {
        let path = Self.resolvedPathAllowingMissingTail(eventPath)
        let rootPath = rootURL.path
        if path == rootPath { return isDirectory }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return false }
        let relative = String(path.dropFirst(prefix.count))
        return Self.shouldRescan(relativePath: relative, isDirectory: isDirectory)
    }

    static func shouldRescan(relativePath: String, isDirectory: Bool) -> Bool {
        if relativePath.isEmpty { return isDirectory }
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }
        if components[0] == ".lattice" {
            return isBoardEventPath(relativePath, isDirectory: isDirectory)
        }
        guard !components.contains(where: skippedDirectoryNames.contains) else { return false }
        if isDirectory { return true }
        return isMarkdownPath(relativePath)
    }

    private static func isBoardEventPath(_ relativePath: String, isDirectory: Bool) -> Bool {
        if relativePath == ".lattice/ids.json" { return !isDirectory }
        if relativePath == ".lattice/tasks" { return isDirectory }
        if relativePath.hasPrefix(".lattice/tasks/") {
            let taskFile = String(relativePath.dropFirst(".lattice/tasks/".count))
            return !isDirectory
                && !taskFile.contains("/")
                && URL(fileURLWithPath: taskFile).pathExtension.lowercased() == "json"
        }
        return false
    }

    private func ignoredEventPaths(_ absolutePaths: [String]) -> Set<String> {
        guard !absolutePaths.isEmpty else { return [] }
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let eventPairs = absolutePaths.compactMap { path -> (absolute: String, relative: String)? in
            let standardized = Self.resolvedPathAllowingMissingTail(path)
            guard standardized.hasPrefix(rootPrefix) else { return nil }
            return (standardized, String(standardized.dropFirst(rootPrefix.count)))
        }
        guard !eventPairs.isEmpty else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", rootURL.path, "check-ignore", "-z", "--stdin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            var bytes = Data()
            for pair in eventPairs {
                bytes.append(contentsOf: pair.relative.utf8)
                bytes.append(0)
            }
            let inputBytes = bytes
            let writeFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                input.fileHandleForWriting.write(inputBytes)
                try? input.fileHandleForWriting.close()
                writeFinished.signal()
            }
            let ignoredData = output.fileHandleForReading.readDataToEndOfFile()
            writeFinished.wait()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let ignored = Set(ignoredData.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
            return Set(eventPairs.compactMap { pair in
                ignored.contains(pair.relative) ? pair.absolute : nil
            })
        } catch {
            return []
        }
    }

    private func stopWatcherOnQueue() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scanAndPublish() {
        guard let rootAccess else {
            updateSnapshot(rootPath: rootURL.path, documents: [], links: [], tickets: [:], truncated: false)
            return
        }

        let discovery = discoverFiles(rootURL: rootURL)
        let boardIndex = loadBoardIndex(rootAccess: rootAccess, rootURL: rootURL)
        let old = indexedFiles
        var updated: [String: IndexedFile] = [:]
        var bytesUsed = 0
        var headingCount = 0
        var linkCount = 0
        var ticketIDCount = 0
        var truncated = discovery.truncated

        for candidate in discovery.files {
            guard updated.count < limits.maximumDocuments else { truncated = true; break }
            guard candidate.signature.size <= limits.maximumFileBytes,
                  bytesUsed + candidate.signature.size <= limits.maximumTotalBytes else {
                truncated = true
                continue
            }
            bytesUsed += candidate.signature.size
            let maximumHeadings = min(limits.maximumHeadingsPerDocument, max(0, limits.maximumTotalHeadings - headingCount))
            let maximumLinks = min(limits.maximumLinksPerDocument, max(0, limits.maximumTotalLinks - linkCount))
            let maximumTicketIDs = min(limits.maximumTicketIDsPerDocument, max(0, limits.maximumTotalTicketIDs - ticketIDCount))
            if let cached = old[candidate.relativePath], cached.signature == candidate.signature {
                let needsReparse =
                    cached.document.headings.count > maximumHeadings ||
                    cached.linkSlotsUsed > maximumLinks ||
                    cached.document.ticketIDs.count > maximumTicketIDs ||
                    (cached.headingsTruncated && maximumHeadings > cached.document.headings.count) ||
                    (cached.linksTruncated && maximumLinks > cached.linkSlotsUsed) ||
                    (cached.ticketIDsTruncated && maximumTicketIDs > cached.document.ticketIDs.count)
                if !needsReparse {
                    updated[candidate.relativePath] = cached
                    headingCount += cached.document.headings.count
                    linkCount += cached.document.links.count
                    ticketIDCount += cached.document.ticketIDs.count
                    truncated = truncated || cached.headingsTruncated || cached.linksTruncated || cached.ticketIDsTruncated
                    continue
                }
            }
            guard let data = try? rootAccess.read(path: candidate.relativePath, maximumBytes: limits.maximumFileBytes) else {
                bytesUsed -= candidate.signature.size
                truncated = true
                continue
            }
            guard let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                bytesUsed -= candidate.signature.size
                truncated = true
                continue
            }
            let bytesBeforeFile = bytesUsed - candidate.signature.size
            guard bytesBeforeFile + data.count <= limits.maximumTotalBytes else {
                truncated = true
                bytesUsed = bytesBeforeFile
                continue
            }
            bytesUsed = bytesBeforeFile + data.count
            let parsed = MarkdownCorpusParser.parse(
                source,
                fileURL: candidate.url,
                rootURL: rootURL,
                maximumHeadings: maximumHeadings,
                maximumLinks: maximumLinks,
                maximumTicketIDs: maximumTicketIDs,
                ticketPrefixes: boardIndex?.prefixes ?? []
            )
            filesReparsed += 1
            headingCount += parsed.document.headings.count
            linkCount += parsed.document.links.count
            ticketIDCount += parsed.document.ticketIDs.count
            if parsed.headingsTruncated || parsed.linksTruncated || parsed.ticketIDsTruncated { truncated = true }
            updated[candidate.relativePath] = IndexedFile(
                signature: candidate.signature,
                document: parsed.document,
                linkSlotsUsed: parsed.linkSlotsUsed,
                headingsTruncated: parsed.headingsTruncated,
                linksTruncated: parsed.linksTruncated,
                ticketIDsTruncated: parsed.ticketIDsTruncated
            )
        }

        indexedFiles = updated
        let orderedDocuments = discovery.files.compactMap { updated[$0.relativePath]?.document }
        let indexedPaths = Set(orderedDocuments.map(\.path))
        let links = orderedDocuments.flatMap(\.links).filter { indexedPaths.contains($0.targetPath) }
        var ticketIDs: [String] = []
        var seenTicketIDs: Set<String> = []
        for document in orderedDocuments {
            for id in document.ticketIDs {
                guard ticketIDs.count < limits.maximumTotalTicketIDs else { truncated = true; break }
                if seenTicketIDs.insert(id).inserted { ticketIDs.append(id) }
            }
            if ticketIDs.count >= limits.maximumTotalTicketIDs { break }
        }
        let tickets = loadTicketCards(for: ticketIDs, boardIndex: boardIndex, rootAccess: rootAccess)
        updateSnapshot(
            rootPath: rootURL.path,
            documents: orderedDocuments,
            links: links,
            tickets: tickets,
            truncated: truncated
        )
    }

    private func updateSnapshot(
        rootPath: String?,
        documents: [MarkdownCorpusDocument],
        links: [MarkdownCorpusLink],
        tickets: [String: MarkdownTicketCard],
        truncated: Bool
    ) {
        let changed = snapshotValue.rootPath != rootPath
            || snapshotValue.documents != documents
            || snapshotValue.links != links
            || snapshotValue.tickets != tickets
            || snapshotValue.truncated != truncated
        if changed { revision += 1 }
        let next = MarkdownCorpusSnapshot(
            rootPath: rootPath,
            documents: documents,
            links: links,
            tickets: tickets,
            truncated: truncated,
            revision: revision,
            filesReparsed: filesReparsed,
            bridgeJSON: changed ? nil : snapshotValue.bridgeJSON
        )
        snapshotValue = next
        if changed { onUpdate(next) }
    }

    private struct Candidate {
        let relativePath: String
        let url: URL
        let signature: Signature
    }

    struct WalkResult {
        let paths: [String]
        let visitedEntries: Int
        let truncated: Bool
    }

    private func discoverFiles(rootURL: URL) -> (files: [Candidate], truncated: Bool) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey
        ]
        var candidates: [Candidate] = []
        let discoveredPaths: [String]
        let walkTruncated: Bool
        if let repositoryPaths = repositoryPaths(rootURL: rootURL) {
            discoveredPaths = repositoryPaths
            walkTruncated = false
        } else {
            let walk = Self.walkedPaths(
                rootURL: rootURL,
                priorityRelativePaths: priorityRelativePaths,
                maximumVisitedEntries: limits.maximumVisitedEntries
            )
            discoveredPaths = walk.paths
            walkTruncated = walk.truncated
        }
        var paths = discoveredPaths
        for priorityPath in priorityRelativePaths where FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent(priorityPath).path
        ) {
            paths.append(priorityPath)
        }
        var seen: Set<String> = []
        var normalizedPaths: [String] = []
        for path in paths {
            let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty, seen.insert(relativePath).inserted else { continue }
            guard !Self.isExcludedPath(relativePath) || priorityRelativePaths.contains(relativePath) else { continue }
            normalizedPaths.append(relativePath)
        }
        var orderedPaths: [(relativePath: String, rank: Int)] = []
        orderedPaths.reserveCapacity(normalizedPaths.count)
        for relativePath in normalizedPaths {
            orderedPaths.append((relativePath: relativePath, rank: proximityRank(for: relativePath)))
        }
        orderedPaths.sort {
            $0.rank == $1.rank ? $0.relativePath < $1.relativePath : $0.rank < $1.rank
        }
        var truncated = walkTruncated || orderedPaths.count > limits.maximumVisitedEntries
        let visitedPaths = orderedPaths.prefix(limits.maximumVisitedEntries)

        for rankedPath in visitedPaths {
            let relative = rankedPath.relativePath
            guard Self.isMarkdownPath(relative) else { continue }
            let url = rootURL.appendingPathComponent(relative)
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isContained(resolved, in: rootURL), let size = values.fileSize, size >= 0 else { continue }
            candidates.append(Candidate(
                relativePath: relative,
                url: resolved,
                signature: Signature(
                    size: size,
                    modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) } ?? ""
                )
            ))
        }

        if candidates.count > limits.maximumDocuments {
            candidates = Array(candidates.prefix(limits.maximumDocuments))
            truncated = true
        }
        return (candidates, truncated)
    }

    private func repositoryPaths(rootURL: URL) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", rootURL.path, "ls-files", "--cached", "--others", "--exclude-standard", "-z",
            "--", "*.md", "*.markdown", "*.mdown"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return data.split(separator: 0).compactMap { bytes in
                let path = String(decoding: bytes, as: UTF8.self)
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
                return path
            }
        } catch {
            return nil
        }
    }

    static func walkedPaths(
        rootURL: URL,
        priorityRelativePaths: [String],
        maximumVisitedEntries: Int
    ) -> WalkResult {
        guard maximumVisitedEntries > 0 else {
            return WalkResult(paths: [], visitedEntries: 0, truncated: true)
        }

        let canonicalRoot = rootURL.standardizedFileURL
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var paths: [String] = []
        var visitedEntries = 0
        var truncated = false
        var visitedDirectories: Set<String> = []
        var pendingDirectories: [String] = []
        var pendingDirectoryIndex = 0

        func visitDirectEntries(in relativeDirectory: String) -> [String] {
            guard !truncated, visitedDirectories.insert(relativeDirectory).inserted else { return [] }
            let directoryURL = relativeDirectory.isEmpty
                ? canonicalRoot
                : canonicalRoot.appendingPathComponent(relativeDirectory, isDirectory: true)
            guard let directoryValues = try? directoryURL.resourceValues(forKeys: keys),
                  directoryValues.isDirectory == true,
                  directoryValues.isSymbolicLink != true,
                  let enumerator = FileManager.default.enumerator(
                    at: directoryURL,
                    includingPropertiesForKeys: Array(keys),
                    options: [],
                    errorHandler: { _, _ in true }
                  ) else { return [] }

            var childDirectories: [String] = []
            while visitedEntries < maximumVisitedEntries,
                  let url = enumerator.nextObject() as? URL {
                visitedEntries += 1
                let relativePath = Self.relativePath(url, under: canonicalRoot)
                if Self.isExcludedPath(relativePath) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isSymbolicLink != true else {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                    if !visitedDirectories.contains(relativePath) {
                        childDirectories.append(relativePath)
                    }
                    continue
                }
                paths.append(relativePath)
            }
            if visitedEntries >= maximumVisitedEntries { truncated = true }
            return childDirectories
        }

        var priorityDirectoryChains: [[String]] = []
        for priorityPath in priorityRelativePaths {
            let components = priorityPath.split(separator: "/").map(String.init)
            guard !priorityPath.hasPrefix("/"),
                  !components.isEmpty,
                  !components.contains("..") else { continue }
            var directory = components.dropLast().joined(separator: "/")
            var chain: [String] = []
            while true {
                if !Self.isExcludedPath(directory) { chain.append(directory) }
                if directory.isEmpty { break }
                let parent = (directory as NSString).deletingLastPathComponent
                directory = parent == "." ? "" : parent
            }
            priorityDirectoryChains.append(chain)
        }

        var preferredDirectories: [String] = []
        var preferredDirectorySet: Set<String> = []
        let maximumChainDepth = priorityDirectoryChains.map(\.count).max() ?? 0
        for depth in 0..<maximumChainDepth {
            for chain in priorityDirectoryChains where depth < chain.count {
                let directory = chain[depth]
                if preferredDirectorySet.insert(directory).inserted {
                    preferredDirectories.append(directory)
                }
            }
        }
        if preferredDirectories.isEmpty { preferredDirectories.append("") }

        for directory in preferredDirectories where !truncated {
            pendingDirectories.append(contentsOf: visitDirectEntries(in: directory))
        }
        while !truncated && pendingDirectoryIndex < pendingDirectories.count {
            let directory = pendingDirectories[pendingDirectoryIndex]
            pendingDirectoryIndex += 1
            pendingDirectories.append(contentsOf: visitDirectEntries(in: directory))
        }

        return WalkResult(
            paths: paths,
            visitedEntries: visitedEntries,
            truncated: truncated
        )
    }

    private func proximityRank(for relativePath: String) -> Int {
        if priorityRelativePaths.contains(relativePath) { return -1 }
        let candidateDirectory = Array(relativePath.split(separator: "/").dropLast().map(String.init))
        return priorityRelativePaths.map { priority in
            let priorityDirectory = Array(priority.split(separator: "/").dropLast().map(String.init))
            var common = 0
            while common < min(candidateDirectory.count, priorityDirectory.count),
                  candidateDirectory[common] == priorityDirectory[common] { common += 1 }
            return candidateDirectory.count + priorityDirectory.count - (2 * common) + 1
        }.min() ?? Int.max
    }

    private static func relativePath(_ url: URL, under rootURL: URL) -> String {
        let rootPath = rootURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func resolvedPathAllowingMissingTail(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            missingComponents.append(url.lastPathComponent)
            url.deleteLastPathComponent()
        }
        url = url.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            url.appendPathComponent(component)
        }
        return url.standardizedFileURL.path
    }

    private static func isExcludedPath(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { skippedDirectoryNames.contains(String($0)) }
    }

    private static func isMarkdownPath(_ relativePath: String) -> Bool {
        ["md", "markdown", "mdown"].contains(URL(fileURLWithPath: relativePath).pathExtension.lowercased())
    }

    private func loadBoardIndex(rootAccess: MarkdownAssetRoot, rootURL: URL) -> BoardIndex? {
        guard Self.isDirectoryWithoutSymlink(rootURL.appendingPathComponent(".lattice", isDirectory: true)) else { return nil }
        var tasksByTicket: [String: String] = [:]
        if let data = try? rootAccess.read(path: ".lattice/ids.json", maximumBytes: limits.maximumBoardBytes),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let map = object["map"] as? [String: String] {
            tasksByTicket = map
        }
        var prefixes = Set(tasksByTicket.keys.compactMap(Self.ticketPrefix))
        if prefixes.isEmpty,
           let data = try? rootAccess.read(path: ".lattice/config.json", maximumBytes: limits.maximumBoardBytes),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["ticket_prefix", "project_code"] {
                if let prefix = object[key] as? String,
                   prefix.range(of: #"^[A-Z][A-Z0-9]{0,15}$"#, options: .regularExpression) != nil {
                    prefixes.insert(prefix)
                }
            }
        }
        return BoardIndex(tasksByTicket: tasksByTicket, prefixes: prefixes)
    }

    private static func ticketPrefix(_ id: String) -> String? {
        guard id.range(of: #"^[A-Z][A-Z0-9]{0,15}-[0-9]{1,9}$"#, options: .regularExpression) != nil else { return nil }
        guard let separator = id.lastIndex(of: "-") else { return nil }
        return String(id[..<separator])
    }

    private func loadTicketCards(
        for ids: [String],
        boardIndex: BoardIndex?,
        rootAccess: MarkdownAssetRoot
    ) -> [String: MarkdownTicketCard] {
        guard !ids.isEmpty, let map = boardIndex?.tasksByTicket else { return [:] }
        var result: [String: MarkdownTicketCard] = [:]
        var taskBytesRead = 0
        for id in ids {
            guard result.count < 2_000, Self.ticketPrefix(id) != nil,
                  taskBytesRead < limits.maximumBoardLookupBytes,
                  let taskID = map[id], taskID.range(of: #"^task_[0-9A-HJKMNP-TV-Z]{26}$"#, options: .regularExpression) != nil,
                  let taskData = try? rootAccess.read(
                    path: ".lattice/tasks/\(taskID).json",
                    maximumBytes: min(256 * 1024, limits.maximumBoardLookupBytes - taskBytesRead)
                  ) else { continue }
            taskBytesRead += taskData.count
            guard let task = try? JSONSerialization.jsonObject(with: taskData) as? [String: Any],
                  task["short_id"] as? String == id,
                  let title = task["title"] as? String, !title.isEmpty,
                  let status = task["status"] as? String, !status.isEmpty else { continue }
            result[id] = MarkdownTicketCard(title: String(title.prefix(200)), status: String(status.prefix(32)))
        }
        return result
    }

    private static func isContained(_ target: URL, in root: URL) -> Bool {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return target.path.hasPrefix(prefix)
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }
}

actor MarkdownCorpusIndexRegistry {
    static let shared = MarkdownCorpusIndexRegistry()

    private struct Subscriber {
        let generation: UInt64
        let fileURL: URL
        let currentPath: String
        let onUpdate: @Sendable (MarkdownCorpusSnapshot, String) -> Void
    }

    private struct Entry {
        let id: UUID
        let indexer: MarkdownCorpusIndexer
        var subscribers: [UUID: Subscriber]
        var snapshot: MarkdownCorpusSnapshot?
    }

    private var entries: [String: Entry] = [:]
    private var panelRoots: [UUID: String] = [:]
    private var panelGenerations: [UUID: UInt64] = [:]

    func update(
        panelID: UUID,
        generation: UInt64,
        fileURL: URL,
        onUpdate: @escaping @Sendable (MarkdownCorpusSnapshot, String) -> Void
    ) {
        guard generation >= panelGenerations[panelID, default: 0] else { return }
        panelGenerations[panelID] = generation
        let rootURL = MarkdownCorpusIndexer.corpusRoot(for: fileURL)
        let rootPath = rootURL.path
        if let previousRoot = panelRoots[panelID], previousRoot != rootPath {
            detach(panelID, from: previousRoot)
        }

        let resolvedFileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let subscriber = Subscriber(
            generation: generation,
            fileURL: resolvedFileURL,
            currentPath: resolvedFileURL.path,
            onUpdate: onUpdate
        )
        if var existing = entries[rootPath] {
            existing.subscribers[panelID] = subscriber
            entries[rootPath] = existing
            panelRoots[panelID] = rootPath
            existing.indexer.updatePriorityFiles(existing.subscribers.values.sorted { $0.currentPath < $1.currentPath }.map(\.fileURL))
            if let snapshot = existing.snapshot { onUpdate(snapshot, subscriber.currentPath) }
            return
        }

        let entryID = UUID()
        let indexer = MarkdownCorpusIndexer(rootURL: rootURL, priorityFileURLs: [resolvedFileURL]) { [weak self] snapshot in
            Task { await self?.publish(rootPath: rootPath, entryID: entryID, snapshot: snapshot) }
        }
        entries[rootPath] = Entry(id: entryID, indexer: indexer, subscribers: [panelID: subscriber], snapshot: nil)
        panelRoots[panelID] = rootPath
        indexer.start()
    }

    func remove(panelID: UUID, generation: UInt64) {
        guard generation >= panelGenerations[panelID, default: 0] else { return }
        panelGenerations[panelID] = generation
        if let rootPath = panelRoots[panelID] { detach(panelID, from: rootPath) }
    }

    private func detach(_ panelID: UUID, from rootPath: String) {
        guard var entry = entries[rootPath] else {
            panelRoots.removeValue(forKey: panelID)
            return
        }
        entry.subscribers.removeValue(forKey: panelID)
        panelRoots.removeValue(forKey: panelID)
        if entry.subscribers.isEmpty {
            entries.removeValue(forKey: rootPath)
            entry.indexer.stop()
        } else {
            entries[rootPath] = entry
        }
    }

    private func publish(rootPath: String, entryID: UUID, snapshot: MarkdownCorpusSnapshot) {
        guard var entry = entries[rootPath], entry.id == entryID else { return }
        if let current = entry.snapshot, snapshot.revision <= current.revision { return }
        entry.snapshot = snapshot
        entries[rootPath] = entry
        for subscriber in entry.subscribers.values {
            subscriber.onUpdate(snapshot, subscriber.currentPath)
        }
    }
}

enum MarkdownCorpusParser {
    private struct RawLink {
        let line: Int
        let text: String
        let href: String
        let section: MarkdownCorpusHeading?
    }

    struct Parsed {
        let document: MarkdownCorpusDocument
        let linkSlotsUsed: Int
        let headingsTruncated: Bool
        let linksTruncated: Bool
        let ticketIDsTruncated: Bool
    }

    static func parse(
        _ source: String,
        fileURL: URL,
        rootURL: URL,
        maximumHeadings: Int,
        maximumLinks: Int,
        maximumTicketIDs: Int,
        ticketPrefixes: Set<String> = []
    ) -> Parsed {
        let lines = source.components(separatedBy: .newlines)
        let frontmatterRange: ClosedRange<Int>? = {
            guard let first = lines.first,
                  first.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) == "---" else { return nil }
            guard let closing = lines.indices.dropFirst().first(where: { index in
                let delimiter = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return delimiter == "---" || delimiter == "..."
            }) else { return nil }
            return 0...closing
        }()
        var headings: [MarkdownCorpusHeading] = []
        var headingAtLine: [Int: MarkdownCorpusHeading] = [:]
        var inFence: (character: Character, length: Int)?
        var headingCounts: [String: Int] = [:]
        var headingsTruncated = false

        func addHeading(text raw: String, level: Int, line: Int) {
            guard headings.count < maximumHeadings else { headingsTruncated = true; return }
            let text = readableHeadingText(raw)
            guard !text.isEmpty else { return }
            let base = slugify(text)
            let duplicate = headingCounts[base, default: 0]
            headingCounts[base] = duplicate + 1
            let heading = MarkdownCorpusHeading(
                level: level,
                text: String(text.prefix(512)),
                slug: duplicate == 0 ? base : "\(base)-\(duplicate)",
                line: line + 1
            )
            headings.append(heading)
            headingAtLine[line] = heading
        }

        var previousLine: String?
        var previousLineNumber = 0
        for (index, line) in lines.enumerated() {
            if frontmatterRange?.contains(index) == true {
                previousLine = nil
                continue
            }
            if isIndentedCodeLine(line) {
                previousLine = nil
                continue
            }
            let trimmed = markdownContentLine(line, lineNumber: index)
            if let fence = inFence {
                if isFenceEnd(trimmed, fence: fence) { inFence = nil }
                previousLine = nil
                continue
            }
            if let fence = fenceStart(trimmed) {
                inFence = fence
                previousLine = nil
                continue
            }
            if let (level, text) = atxHeading(trimmed) {
                addHeading(text: text, level: level, line: index)
            } else if let previousLine, let level = setextLevel(trimmed) {
                addHeading(text: previousLine, level: level, line: previousLineNumber)
            }
            previousLine = trimmed.isEmpty ? nil : trimmed
            previousLineNumber = index
        }

        var rawLinks: [RawLink] = []
        var linksTruncated = false
        var ticketIDsTruncated = false
        var currentSection: MarkdownCorpusHeading?
        inFence = nil
        var ids: Set<String> = []
        let ticketPattern: NSRegularExpression? = {
            let prefixes = ticketPrefixes.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
                .map(NSRegularExpression.escapedPattern(for:))
            guard !prefixes.isEmpty else { return nil }
            return try? NSRegularExpression(pattern: #"\b(?:"# + prefixes.joined(separator: "|") + #")-[0-9]{1,9}\b"#)
        }()
        let linkPattern = try! NSRegularExpression(
            pattern: #"\[([^\]]+)\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)"#
        )
        let codePattern = try! NSRegularExpression(pattern: #"`+[^`]*`+"#)

        for (index, line) in lines.enumerated() {
            if frontmatterRange?.contains(index) == true || isIndentedCodeLine(line) { continue }
            let trimmed = markdownContentLine(line, lineNumber: index)
            if let fence = inFence {
                if isFenceEnd(trimmed, fence: fence) { inFence = nil }
                continue
            }
            if let fence = fenceStart(trimmed) { inFence = fence; continue }
            if let heading = headingAtLine[index] { currentSection = heading }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let withoutCode = codePattern.stringByReplacingMatches(in: line, range: range, withTemplate: " ")
            let visibleRange = NSRange(withoutCode.startIndex..<withoutCode.endIndex, in: withoutCode)
            for match in ticketPattern?.matches(in: withoutCode, range: visibleRange) ?? [] {
                guard let valueRange = Range(match.range, in: withoutCode) else { continue }
                let id = String(withoutCode[valueRange])
                if ids.contains(id) { continue }
                guard ids.count < maximumTicketIDs else { ticketIDsTruncated = true; continue }
                ids.insert(id)
            }
            guard line.utf8.count <= 16 * 1024 else {
                linksTruncated = true
                continue
            }
            let linkMatches = linkPattern.matches(in: withoutCode, range: visibleRange)
            for match in linkMatches.prefix(maximumLinks) {
                guard let labelRange = Range(match.range(at: 1), in: withoutCode),
                      let hrefRange = Range(match.range(at: match.range(at: 2).location != NSNotFound ? 2 : 3), in: withoutCode) else { continue }
                rawLinks.append(RawLink(
                    line: index + 1,
                    text: String(withoutCode[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines),
                    href: String(withoutCode[hrefRange]),
                    section: currentSection
                ))
            }
            if linkMatches.count > maximumLinks { linksTruncated = true }
        }

        let sourcePath = fileURL.standardizedFileURL.path
        let sourceTitle = fileURL.lastPathComponent
        let links: [MarkdownCorpusLink] = rawLinks.compactMap { raw in
            guard case .markdown(let target) = MarkdownLinkTarget.resolve(raw.href, documentPath: sourcePath) else { return nil }
            let targetURL = target.resolvingSymlinksInPath().standardizedFileURL
            guard isContained(targetURL, in: rootURL) else { return nil }
            let fragment = URLComponents(url: target, resolvingAgainstBaseURL: false)?.fragment
            return MarkdownCorpusLink(
                sourcePath: sourcePath,
                sourceTitle: sourceTitle,
                sourceSection: raw.section?.text,
                sourceSectionSlug: raw.section?.slug,
                line: raw.line,
                text: String(raw.text.prefix(256)),
                targetPath: targetURL.path,
                targetFragment: fragment.map { String($0.prefix(256)) }
            )
        }
        let relativePath = String(sourcePath.dropFirst(rootURL.path == "/" ? 1 : rootURL.path.count + 1))
        let ticketIDs = ids.sorted()
        let document = MarkdownCorpusDocument(
            path: sourcePath,
            relativePath: relativePath,
            title: sourceTitle,
            headings: headings,
            links: links,
            ticketIDs: ticketIDs
        )
        return Parsed(
            document: document,
            linkSlotsUsed: rawLinks.count,
            headingsTruncated: headingsTruncated,
            linksTruncated: linksTruncated,
            ticketIDsTruncated: ticketIDsTruncated
        )
    }

    private static func markdownContentLine(_ line: String, lineNumber: Int) -> String {
        if lineNumber == 0, line.first == "\u{FEFF}" { return String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var spaces = 0
        for character in line {
            if character == " " { spaces += 1; continue }
            if character == "\t" { return true }
            return spaces >= 4
        }
        return false
    }

    private static func atxHeading(_ line: String) -> (Int, String)? {
        let chars = Array(line)
        var count = 0
        while count < chars.count, count < 6, chars[count] == "#" { count += 1 }
        guard count > 0, count == chars.count || chars[count].isWhitespace else { return nil }
        var text = String(chars.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        while text.last == "#" { text.removeLast() }
        return (count, text.trimmingCharacters(in: .whitespaces))
    }

    private static func setextLevel(_ line: String) -> Int? {
        if line.range(of: #"^=+\s*$"#, options: .regularExpression) != nil { return 1 }
        if line.range(of: #"^-+\s*$"#, options: .regularExpression) != nil { return 2 }
        return nil
    }

    private static func fenceStart(_ line: String) -> (character: Character, length: Int)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let length = trimmed.prefix(while: { $0 == first }).count
        return length >= 3 ? (first, length) : nil
    }

    private static func isFenceEnd(_ line: String, fence: (character: Character, length: Int)) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let count = trimmed.prefix(while: { $0 == fence.character }).count
        return count >= fence.length && trimmed.dropFirst(count).allSatisfy(\.isWhitespace)
    }

    private static func readableHeadingText(_ source: String) -> String {
        let codeSpanPattern = try? NSRegularExpression(pattern: #"`+([^`]+)`+"#)
        var value = source
        var codeSegments: [String] = []
        if let codeSpanPattern {
            let matches = codeSpanPattern.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source))
            var rebuilt = ""
            var cursor = source.startIndex
            for match in matches {
                guard let wholeRange = Range(match.range, in: source),
                      let contentRange = Range(match.range(at: 1), in: source) else { continue }
                rebuilt += source[cursor..<wholeRange.lowerBound]
                let marker = "\u{E000}\(codeSegments.count)\u{E001}"
                rebuilt += marker
                codeSegments.append(String(source[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines))
                cursor = wholeRange.upperBound
            }
            rebuilt += source[cursor...]
            value = rebuilt
        }
        let patterns: [(String, String)] = [
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"<[^>]+>"#, ""),
            (#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, "$1"),
            (#"__(?=\S)(.+?)(?<=\S)__"#, "$1"),
            (#"~~(?=\S)(.+?)(?<=\S)~~"#, "$1"),
            (#"(?<!\\)\*(?=\S)(.+?)(?<=\S)\*"#, "$1"),
            (#"(?<![\p{L}\p{N}_])_(?=\S)(.+?)(?<=\S)_(?![\p{L}\p{N}_])"#, "$1"),
            (#"[`~]"#, ""),
            (#"\\([\\`*_{}\[\]()#+.!<>|])"#, "$1")
        ]
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(value.startIndex..<value.endIndex, in: value)
                value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
            }
        }
        for (index, code) in codeSegments.enumerated() {
            value = value.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: code)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func slugify(_ text: String) -> String {
        let lower = text.lowercased()
        var filtered = String.UnicodeScalarView()
        for scalar in lower.unicodeScalars {
            let category = scalar.properties.generalCategory
            let isLetter = [.uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter].contains(category)
            let isNumber = [.decimalNumber, .letterNumber, .otherNumber].contains(category)
            if isLetter || isNumber || CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "_" || scalar == "-" {
                filtered.append(CharacterSet.whitespacesAndNewlines.contains(scalar) ? "-" : scalar)
            }
        }
        return String(filtered)
    }

    private static func isContained(_ target: URL, in root: URL) -> Bool {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return target.path.hasPrefix(prefix)
    }
}
