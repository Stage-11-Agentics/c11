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
struct ClaudeCodeScraper: ConversationScraper {
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

/// Bounded filesystem I/O over `~/.codex/sessions/`. Reads filename + mtime +
/// size for the session id (as `ClaudeCodeScraper` does) and, uniquely, a
/// **bounded, allowlisted** first-line read to recover each session's real
/// working directory.
///
/// **Why the head read (C11-164 / RES-2):** Codex stores sessions flat by
/// date (`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`), NOT under
/// a per-cwd directory like Claude Code. So the filename cannot say which pane
/// a session belongs to, and the prior scraper stamped the *querying surface's*
/// cwd onto every candidate — making `CodexStrategy`'s cwd filter a structural
/// no-op (every candidate looked same-cwd → distinct-workspace codex sessions
/// all read as mutually ambiguous and none resumed). Recovering the real cwd
/// from the rollout header restores the filter.
///
/// **Privacy contract** (architecture doc §"Privacy contract for scrape"):
/// the head read is capped at `codexHeadMaxBytes` and only the `cwd` string
/// value is extracted via `parseCodexCwd`; no other field — and no transcript
/// content — is parsed, retained, or logged. Codex writes the session-meta
/// record as the first JSONL line with `payload.cwd` ahead of the large
/// `instructions` field, so the cap captures cwd without slurping the body.
struct CodexScraper: ConversationScraper {
    let kind: String = "codex"
    static let defaultMaxCandidates: Int = 16
    /// Head-read byte cap for cwd recovery. Generous enough to include
    /// `payload.cwd` (which precedes `payload.instructions` in the observed
    /// rollout format) while staying bounded far below any transcript body.
    static let codexHeadMaxBytes: Int = 8192

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
            // Codex names sessions `rollout-<ISO8601-with-dashes>-<uuid>.jsonl`
            // (e.g. `rollout-2026-01-31T21-29-57-019c1709-...-5144ceccdad7`),
            // so the session id is the trailing 36-char UUID, not the whole
            // stem. `suffix(36)` also handles a bare `<uuid>.jsonl` (stem is
            // already 36 chars); anything shorter or malformed fails the UUID
            // guard below and is dropped.
            let stem = String(entry.fileName.dropLast(".jsonl".count))
            let id = String(stem.suffix(36))
            guard isValidConversationUUID(id) else { return nil }
            // Recover the session's REAL cwd from its rollout header (bounded,
            // allowlisted). On any read/parse miss the candidate keeps `cwd ==
            // nil`, which the strategy treats as "can't discriminate" — the
            // prior behaviour, never worse. We deliberately do NOT fall back to
            // the querying surface's `cwd`: stamping it back would re-introduce
            // the same-cwd no-op this recovery exists to remove.
            let head = filesystem.readSessionHead(
                atPath: entry.url.path,
                maxBytes: Self.codexHeadMaxBytes
            )
            let realCwd = head.flatMap { Self.parseCodexCwd(fromHead: $0) }
            return ScrapeCandidate(
                id: id,
                filePath: entry.url.path,
                mtime: entry.mtime,
                size: entry.size,
                cwd: realCwd
            )
        }
    }

    /// Extract ONLY the `cwd` string value from a bounded rollout header.
    /// Deliberately not a full JSON parse: the header may be truncated at the
    /// byte cap, and a narrow scan for the `"cwd"` key guarantees no other
    /// field is ever read. Handles the minimal JSON string escapes that occur
    /// in filesystem paths (`\/`, `\\`, `\"`). Returns nil if the key is
    /// absent within the capped head. Package-visible for unit testing.
    static func parseCodexCwd(fromHead head: String) -> String? {
        let scalars = Array(head.unicodeScalars)
        let key = Array("\"cwd\"".unicodeScalars)
        // Find the first `"cwd"` occurrence.
        var i = 0
        let n = scalars.count
        func matchesKey(at pos: Int) -> Bool {
            guard pos + key.count <= n else { return false }
            for k in 0..<key.count where scalars[pos + k] != key[k] { return false }
            return true
        }
        while i < n {
            if scalars[i] == "\"", matchesKey(at: i) {
                var j = i + key.count
                // Skip whitespace up to the colon.
                while j < n, scalars[j] == " " || scalars[j] == "\t" { j += 1 }
                guard j < n, scalars[j] == ":" else { i += 1; continue }
                j += 1
                while j < n, scalars[j] == " " || scalars[j] == "\t" { j += 1 }
                guard j < n, scalars[j] == "\"" else { return nil }
                j += 1
                // Read the string value, honoring escapes, until the closing ".
                var out = String.UnicodeScalarView()
                while j < n {
                    let c = scalars[j]
                    if c == "\\" {
                        guard j + 1 < n else { return nil } // truncated escape
                        let e = scalars[j + 1]
                        switch e {
                        case "\"": out.append("\"")
                        case "\\": out.append("\\")
                        case "/": out.append("/")
                        default: out.append(e) // pass through other escapes
                        }
                        j += 2
                        continue
                    }
                    if c == "\"" {
                        let value = String(out)
                        return value.isEmpty ? nil : value
                    }
                    out.append(c)
                    j += 1
                }
                // Closing quote fell outside the capped head — give up rather
                // than return a partial path.
                return nil
            }
            i += 1
        }
        return nil
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

    /// C11-164 (RES-2): bounded read of a session file's head, capped at
    /// `maxBytes`. This is the SINGLE content-reading method in the scrape
    /// rail, added solely so `CodexScraper` can recover a session's real
    /// working directory from its rollout header — Codex stores sessions flat
    /// (`~/.codex/sessions/.../<uuid>.jsonl`), not under a cwd-slug directory,
    /// so filename + mtime alone can't tell which pane a session belongs to,
    /// and every candidate looked same-cwd (the disambiguation no-op the
    /// architecture doc flagged). Honors the privacy contract: reads at most
    /// `maxBytes` and the caller extracts ONLY the allowlisted `cwd` field —
    /// no transcript content is retained or logged. Returns nil if the file
    /// can't be read. A protocol-extension default returns nil so existing
    /// stat-only mocks keep compiling (they simply provide no cwd recovery).
    func readSessionHead(atPath path: String, maxBytes: Int) -> String?
}

extension ConversationFilesystem {
    /// Default: no content read. Keeps stat-only mocks source-compatible and
    /// means a filesystem that opts out of head reads degrades to the prior
    /// no-cwd-recovery behaviour (candidate `cwd == nil`), never worse.
    func readSessionHead(atPath path: String, maxBytes: Int) -> String? { nil }
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

    /// Bounded head read: opens the file, reads at most `maxBytes`, and
    /// returns the first line (up to the first newline) as a UTF-8 string.
    /// Never reads beyond the cap — a large transcript body after the header
    /// is never pulled into memory. The caller extracts only the `cwd` field.
    func readSessionHead(atPath path: String, maxBytes: Int) -> String? {
        guard maxBytes > 0 else { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maxBytes) ?? Data()
        } catch {
            return nil
        }
        guard !data.isEmpty else { return nil }
        // First line only (session-meta record). If no newline is within the
        // cap, use the whole capped buffer.
        let lineData: Data
        if let nl = data.firstIndex(of: 0x0A) {
            lineData = data.subdata(in: data.startIndex..<nl)
        } else {
            lineData = data
        }
        return String(decoding: lineData, as: UTF8.self)
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
