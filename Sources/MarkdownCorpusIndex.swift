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
        links.filter { link in
            guard link.targetPath == path else { return false }
            guard let fragment, !fragment.isEmpty else { return true }
            return link.targetFragment?.caseInsensitiveCompare(fragment) == .orderedSame
        }
    }

    func bridgeValue(currentPath: String?) -> [String: Any] {
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
        return [
            "root": rootPath as Any? ?? NSNull(),
            "current": currentPath as Any? ?? NSNull(),
            "documents": documentValues,
            "links": linkValues,
            "tickets": ticketValues,
            "truncated": truncated,
            "revision": revision
        ]
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

    let rootURL: URL
    private let rootAccess: MarkdownAssetRoot?
    private let queue = DispatchQueue(label: "com.stage11.c11.markdown-corpus", qos: .utility)
    private let limits: Limits
    private let onUpdate: @Sendable (MarkdownCorpusSnapshot) -> Void
    private var stream: FSEventStreamRef?
    private var indexedFiles: [String: IndexedFile] = [:]
    private var snapshotValue = MarkdownCorpusSnapshot.empty
    private var revision = 0
    private var filesReparsed = 0
    private var scanQueued = false
    private var stopped = false

    init(
        rootURL: URL,
        limits: Limits = Limits(),
        onUpdate: @escaping @Sendable (MarkdownCorpusSnapshot) -> Void
    ) {
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        self.rootURL = canonicalRoot
        rootAccess = MarkdownAssetRoot(directory: canonicalRoot)
        self.limits = limits
        self.onUpdate = onUpdate
    }

    convenience init(
        fileURL: URL,
        limits: Limits = Limits(),
        onUpdate: @escaping @Sendable (MarkdownCorpusSnapshot) -> Void
    ) {
        self.init(rootURL: Self.corpusRoot(for: fileURL), limits: limits, onUpdate: onUpdate)
    }

    static func corpusRoot(for fileURL: URL) -> URL {
        MarkdownDocumentRoot.corpusRoot(for: fileURL)
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

    private func scheduleRescan() {
        queue.async { [weak self] in
            guard let self, !self.stopped, !self.scanQueued else { return }
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
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<MarkdownCorpusIndexer>.fromOpaque(info).takeUnretainedValue().scheduleRescan()
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

    private func stopWatcherOnQueue() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scanAndPublish() {
        guard let rootAccess else {
            revision += 1
            snapshotValue = MarkdownCorpusSnapshot(
                rootPath: rootURL.path, documents: [], links: [], tickets: [:],
                truncated: false, revision: revision, filesReparsed: filesReparsed
            )
            onUpdate(snapshotValue)
            return
        }

        let discovery = discoverFiles(rootURL: rootURL)
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
                maximumTicketIDs: maximumTicketIDs
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
        revision += 1
        let orderedDocuments = updated.keys.sorted().compactMap { updated[$0]?.document }
        let indexedPaths = Set(orderedDocuments.map(\.path))
        let links = orderedDocuments.flatMap(\.links).filter { indexedPaths.contains($0.targetPath) }
        var ticketIDs = Set<String>()
        for document in orderedDocuments {
            for id in document.ticketIDs {
                guard ticketIDs.count < limits.maximumTotalTicketIDs else { truncated = true; break }
                ticketIDs.insert(id)
            }
            if ticketIDs.count >= limits.maximumTotalTicketIDs { break }
        }
        let tickets = loadTicketCards(for: ticketIDs, rootAccess: rootAccess, rootURL: rootURL)
        snapshotValue = MarkdownCorpusSnapshot(
            rootPath: rootURL.path,
            documents: orderedDocuments,
            links: links,
            tickets: tickets,
            truncated: truncated,
            revision: revision,
            filesReparsed: filesReparsed
        )
        onUpdate(snapshotValue)
    }

    private struct Candidate {
        let relativePath: String
        let url: URL
        let signature: Signature
    }

    private func discoverFiles(rootURL: URL) -> (files: [Candidate], truncated: Bool) {
        let excluded = Set([".git", "node_modules", "DerivedData", "build", "dist", ".build"])
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey
        ]
        var candidates: [Candidate] = []
        var visited = 0
        var truncated = false
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return ([], false) }

        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > limits.maximumVisitedEntries {
                truncated = true
                break
            }
            if excluded.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true,
                  ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased()) else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isContained(resolved, in: rootURL),
                  let size = values.fileSize, size >= 0 else { continue }
            let rootPath = rootURL.path
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1))
            candidates.append(Candidate(
                relativePath: relative,
                url: resolved,
                signature: Signature(
                    size: size,
                    modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    resourceIdentifier: String(describing: values.fileResourceIdentifier ?? "")
                )
            ))
        }

        candidates.sort { $0.relativePath < $1.relativePath }
        if candidates.count > limits.maximumDocuments {
            candidates = Array(candidates.prefix(limits.maximumDocuments))
            truncated = true
        }
        return (candidates, truncated)
    }

    private func loadTicketCards(
        for ids: Set<String>,
        rootAccess: MarkdownAssetRoot,
        rootURL: URL
    ) -> [String: MarkdownTicketCard] {
        guard !ids.isEmpty,
              Self.isDirectoryWithoutSymlink(rootURL.appendingPathComponent(".lattice", isDirectory: true)),
              let data = try? rootAccess.read(path: ".lattice/ids.json", maximumBytes: limits.maximumBoardBytes),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = object["map"] as? [String: String] else { return [:] }

        var result: [String: MarkdownTicketCard] = [:]
        var taskBytesRead = 0
        for id in ids.sorted() {
            guard result.count < 2_000, id.range(of: #"^C11-[0-9]{1,9}$"#, options: .regularExpression) != nil,
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
        let onUpdate: @Sendable (MarkdownCorpusSnapshot) -> Void
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
        onUpdate: @escaping @Sendable (MarkdownCorpusSnapshot) -> Void
    ) {
        guard generation >= panelGenerations[panelID, default: 0] else { return }
        panelGenerations[panelID] = generation
        let rootURL = MarkdownCorpusIndexer.corpusRoot(for: fileURL)
        let rootPath = rootURL.path
        if let previousRoot = panelRoots[panelID], previousRoot != rootPath {
            detach(panelID, from: previousRoot)
        }

        let subscriber = Subscriber(generation: generation, onUpdate: onUpdate)
        if var existing = entries[rootPath] {
            existing.subscribers[panelID] = subscriber
            entries[rootPath] = existing
            panelRoots[panelID] = rootPath
            if let snapshot = existing.snapshot { onUpdate(snapshot) }
            return
        }

        let entryID = UUID()
        let indexer = MarkdownCorpusIndexer(rootURL: rootURL) { [weak self] snapshot in
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
        entry.snapshot = snapshot
        entries[rootPath] = entry
        for subscriber in entry.subscribers.values {
            subscriber.onUpdate(snapshot)
        }
    }
}

private enum MarkdownCorpusParser {
    private struct RawLink {
        let line: Int
        let text: String
        let href: String
        let section: MarkdownCorpusHeading?
    }

    private struct Parsed {
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
        maximumTicketIDs: Int
    ) -> Parsed {
        let lines = source.components(separatedBy: .newlines)
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
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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
        let ticketPattern = try! NSRegularExpression(pattern: #"\bC11-[0-9]{1,9}\b"#)
        let linkPattern = try! NSRegularExpression(
            pattern: #"\[([^\]]+)\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)"#
        )
        let codePattern = try! NSRegularExpression(pattern: #"`+[^`]*`+"#)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = inFence {
                if isFenceEnd(trimmed, fence: fence) { inFence = nil }
                continue
            }
            if let fence = fenceStart(trimmed) { inFence = fence; continue }
            if let heading = headingAtLine[index] { currentSection = heading }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let withoutCode = codePattern.stringByReplacingMatches(in: line, range: range, withTemplate: " ")
            let visibleRange = NSRange(withoutCode.startIndex..<withoutCode.endIndex, in: withoutCode)
            for match in ticketPattern.matches(in: withoutCode, range: visibleRange) {
                guard let valueRange = Range(match.range, in: withoutCode) else { continue }
                let id = String(withoutCode[valueRange])
                if ids.contains(id) { continue }
                guard ids.count < maximumTicketIDs else { ticketIDsTruncated = true; continue }
                ids.insert(id)
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
        var value = source
        let patterns: [(String, String)] = [
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"<[^>]+>"#, ""),
            (#"[`*_~]"#, ""),
            (#"\\([\\`*_{}\[\]()#+.!<>|])"#, "$1")
        ]
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(value.startIndex..<value.endIndex, in: value)
                value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func slugify(_ text: String) -> String {
        let lower = text.lowercased()
        var filtered = String.UnicodeScalarView()
        for scalar in lower.unicodeScalars where CharacterSet.letters.contains(scalar)
            || CharacterSet.decimalDigits.contains(scalar)
            || scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "_" || scalar == "-" {
            filtered.append(scalar)
        }
        return String(filtered).replacingOccurrences(of: #"\s"#, with: "-", options: .regularExpression)
    }

    private static func isContained(_ target: URL, in root: URL) -> Bool {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return target.path.hasPrefix(prefix)
    }
}
