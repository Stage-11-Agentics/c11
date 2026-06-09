import Foundation

/// Bounded filesystem I/O over `~/.claude/projects/`, where Claude Code
/// stores per-cwd transcripts as `<cwd-slug>/<session-id>.jsonl`.
///
/// **Privacy contract** (see architecture doc §"Privacy contract for scrape"):
/// reads metadata only — filename + mtime + size. Filename carries the
/// session id. Transcript bytes are NEVER opened, copied, or logged.
///
/// Scope:
/// - At most `maxCandidates` (default 16) most-recent transcripts by mtime.
/// - Filename pattern: `<uuid>.jsonl` where uuid is the Claude session id.
/// - Transcripts live one level deep under a project-slug directory, so the
///   recursive lister is used (mirrors `CodexScraper`). The exact-path stat
///   used by crash-recovery verification lives on the strategy
///   (`ClaudeCodeStrategy.transcriptExists`); this scraper is the bounded
///   top-N pull-fallback seam.
struct ClaudeCodeScraper: Sendable {
    let kind: String = "claude-code"
    static let defaultMaxCandidates: Int = 16

    /// Filesystem dependency. Tests pass a mock that produces fixture
    /// session-storage layouts without touching the real `~/.claude/`.
    let filesystem: ConversationFilesystem
    let maxCandidates: Int

    init(
        filesystem: ConversationFilesystem = DefaultConversationFilesystem(),
        maxCandidates: Int = ClaudeCodeScraper.defaultMaxCandidates
    ) {
        self.filesystem = filesystem
        self.maxCandidates = maxCandidates
    }

    /// Resolve `~/.claude/projects/`. Returns nil if HOME isn't set.
    func projectsRoot() -> URL? {
        guard let home = filesystem.homeDirectory else { return nil }
        return home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Top-N candidates by mtime. Empty list when the directory doesn't
    /// exist (Claude Code never ran on this machine). Walks the project-slug
    /// subdirectories recursively because transcripts are nested one level
    /// under `<cwd-slug>/`.
    func candidates(cwd: String? = nil) -> [ScrapeCandidate] {
        guard let root = projectsRoot() else { return [] }
        let entries = filesystem.listSessionsRecursivelyByMtime(
            root,
            extensionFilter: "jsonl",
            max: maxCandidates
        )
        return entries.compactMap { entry in
            let id = String(entry.fileName.dropLast(".jsonl".count))
            guard isValidConversationUUID(id) else { return nil }
            return ScrapeCandidate(
                id: id,
                filePath: entry.url.path,
                mtime: entry.mtime,
                size: entry.size,
                cwd: cwd
            )
        }
    }
}

/// Bounded filesystem I/O over `~/.codex/sessions/`. Same privacy contract
/// as `ClaudeCodeScraper`: reads metadata only; never opens transcripts.
///
/// Codex filenames are `<uuid>.jsonl`; the scraper recovers the session id
/// from the filename without parsing content.
struct CodexScraper: Sendable {
    let kind: String = "codex"
    static let defaultMaxCandidates: Int = 16

    let filesystem: ConversationFilesystem
    let maxCandidates: Int

    init(
        filesystem: ConversationFilesystem = DefaultConversationFilesystem(),
        maxCandidates: Int = CodexScraper.defaultMaxCandidates
    ) {
        self.filesystem = filesystem
        self.maxCandidates = maxCandidates
    }

    func sessionsRoot() -> URL? {
        guard let home = filesystem.homeDirectory else { return nil }
        return home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Codex stores sessions in subdirectories by year/month/day; walk
    /// one level deeper than Claude. The filesystem contract handles
    /// recursion via `listSessionsRecursivelyByMtime`.
    func candidates(cwd: String? = nil) -> [ScrapeCandidate] {
        guard let root = sessionsRoot() else { return [] }
        let entries = filesystem.listSessionsRecursivelyByMtime(
            root,
            extensionFilter: "jsonl",
            max: maxCandidates
        )
        return entries.compactMap { entry in
            let id = String(entry.fileName.dropLast(".jsonl".count))
            guard isValidConversationUUID(id) else { return nil }
            return ScrapeCandidate(
                id: id,
                filePath: entry.url.path,
                mtime: entry.mtime,
                size: entry.size,
                cwd: cwd
            )
        }
    }
}

/// Filesystem dependency injected into scrapers so tests stub directory
/// listing without touching the real `~/.claude/` or `~/.codex/`.
protocol ConversationFilesystem: Sendable {
    var homeDirectory: URL? { get }

    /// List entries in `directory`, sorted newest-first by mtime, capped
    /// at `max`. Returns an empty array if the directory doesn't exist
    /// or can't be read.
    func listDirectoryByMtime(
        _ directory: URL,
        max: Int
    ) -> [ConversationFilesystemEntry]

    /// Recursively walk `root`, collect files with a given extension,
    /// sort by mtime newest-first, cap at `max`. Bounded — never reads
    /// file contents, only `stat` data.
    func listSessionsRecursivelyByMtime(
        _ root: URL,
        extensionFilter: String,
        max: Int
    ) -> [ConversationFilesystemEntry]

    /// Stat-only existence check for a single path. Used by crash-recovery
    /// transcript verification (`ClaudeCodeStrategy.transcriptExists`).
    /// Never opens the file — honors the scrape privacy contract.
    func fileExists(atPath path: String) -> Bool
}

struct ConversationFilesystemEntry: Sendable, Equatable {
    let url: URL
    let fileName: String
    let mtime: Date
    let size: Int64

    init(url: URL, fileName: String, mtime: Date, size: Int64) {
        self.url = url
        self.fileName = fileName
        self.mtime = mtime
        self.size = size
    }
}

/// Production filesystem implementation. Bounded — never reads file
/// contents; uses `attributesOfItem` for stat data.
struct DefaultConversationFilesystem: ConversationFilesystem {
    init() {}

    var homeDirectory: URL? {
        FileManager.default.homeDirectoryForCurrentUser
    }

    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func listDirectoryByMtime(
        _ directory: URL,
        max: Int
    ) -> [ConversationFilesystemEntry] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue else {
            return []
        }
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var entries: [ConversationFilesystemEntry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            let mtime = (attrs[.modificationDate] as? Date) ?? Date.distantPast
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            entries.append(ConversationFilesystemEntry(
                url: url, fileName: name, mtime: mtime, size: size
            ))
        }
        entries.sort { $0.mtime > $1.mtime }
        return Array(entries.prefix(max))
    }

    func listSessionsRecursivelyByMtime(
        _ root: URL,
        extensionFilter: String,
        max: Int
    ) -> [ConversationFilesystemEntry] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue else {
            return []
        }
        let dotExt = "." + extensionFilter
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var entries: [ConversationFilesystemEntry] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasSuffix(dotExt) else { continue }
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey
            ]) else { continue }
            guard values.isRegularFile == true else { continue }
            let mtime = values.contentModificationDate ?? Date.distantPast
            let size = Int64(values.fileSize ?? 0)
            entries.append(ConversationFilesystemEntry(
                url: url, fileName: name, mtime: mtime, size: size
            ))
        }
        entries.sort { $0.mtime > $1.mtime }
        return Array(entries.prefix(max))
    }
}
