import Foundation

/// Bounded filesystem I/O over `~/.omp/agent/sessions/`, where oh-my-pi
/// (`omp`) stores per-cwd transcripts as
/// `<cwd-slug>/<ts>_<uuid>.jsonl` alongside a sibling `<ts>_<uuid>/`
/// directory of per-session `*.log` files.
///
/// **Privacy contract** (see architecture doc §"Privacy contract for scrape"):
/// reads metadata only — filename + mtime + size. The session id is the
/// trailing UUID in the filename. Transcript bytes are NEVER opened, copied,
/// or logged.
///
/// Scope:
/// - At most `maxCandidates` (default 16) most-recent transcripts by mtime.
/// - Filename pattern: `<ts>_<uuid>.jsonl`. The timestamp uses dashes, so the
///   single `_` separates it from the UUID; the id is the substring after the
///   **last** `_` with `.jsonl` stripped.
/// - The id is a UUIDv7 (`019f0b94-be86-7000-…`), but still 8-4-4-4-12 hex, so
///   `isValidConversationUUID` (the shared v4-grammar check) accepts it.
/// - The per-session `*.log` files live in a sibling directory with no
///   `.jsonl` extension, so the recursive walker's `extensionFilter: "jsonl"`
///   excludes them for free — no extra filtering needed here.
struct OmpScraper: ConversationScraper {
    let kind: String = "omp"
    static let defaultMaxCandidates: Int = 16

    /// Filesystem dependency. Tests pass a mock that produces fixture
    /// session-storage layouts without touching the real `~/.omp/`.
    let filesystem: ConversationFilesystem
    let maxCandidates: Int

    init(
        filesystem: ConversationFilesystem = DefaultConversationFilesystem(),
        maxCandidates: Int = OmpScraper.defaultMaxCandidates
    ) {
        self.filesystem = filesystem
        self.maxCandidates = maxCandidates
    }

    /// Resolve `~/.omp/agent/sessions/`. Returns nil if HOME isn't set.
    func sessionsRoot() -> URL? {
        guard let home = filesystem.homeDirectory else { return nil }
        return home
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Top-N candidates by mtime. Empty list when the directory doesn't exist
    /// (omp never ran on this machine). Walks the cwd-slug subdirectories
    /// recursively because transcripts are nested one level under
    /// `<cwd-slug>/`. The `jsonl` extension filter drops the sibling
    /// `*.log` subdir files.
    func candidates(cwd: String? = nil) -> [ScrapeCandidate] {
        guard let root = sessionsRoot() else { return [] }
        let entries = filesystem.listSessionsRecursivelyByMtime(
            root,
            extensionFilter: "jsonl",
            max: maxCandidates
        )
        return entries.compactMap { entry in
            // `<ts>_<uuid>.jsonl` → drop extension, take the substring after
            // the LAST underscore. Reject filenames without a `_`.
            let stem = String(entry.fileName.dropLast(".jsonl".count))
            guard let underscore = stem.lastIndex(of: "_") else { return nil }
            let id = String(stem[stem.index(after: underscore)...])
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
