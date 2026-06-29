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

    /// omp's per-cwd session-directory name. Verified against the real store:
    /// the slug is the cwd with the home-directory prefix stripped and every
    /// `/` mapped to `-`, e.g. `/Users/atin/Projects/Stage11/code/c11` →
    /// `-Projects-Stage11-code-c11`. No lowercasing; existing dashes are
    /// preserved. This differs from pi's full-path `--<…>--` convention, so it
    /// is deliberately NOT a copy of `PiScraper.sessionSlug`.
    static func sessionSlug(forCwd cwd: String, homeDirectory: URL?) -> String {
        var path = cwd
        if let home = homeDirectory?.path, path.hasPrefix(home) {
            path = String(path.dropFirst(home.count))
        }
        return path.replacingOccurrences(of: "/", with: "-")
    }

    /// Top-N candidates by mtime. When `cwd` is known, scopes the walk to that
    /// cwd's slug directory (omp stores `<slug>/<ts>_<uuid>.jsonl` one level
    /// deep) so exact resume resolves *this* project's session rather than the
    /// machine-wide newest. Without scoping every candidate is stamped with the
    /// surface cwd, so `OmpStrategy`'s cwd filter cannot disambiguate and a
    /// multi-project store either bleeds a foreign session or safe-skips. With
    /// no `cwd`, falls back to the whole-tree top-N. The `.jsonl` suffix check
    /// drops the sibling per-session `*.log` subdir files.
    func candidates(cwd: String? = nil) -> [ScrapeCandidate] {
        guard let root = sessionsRoot() else { return [] }
        let entries: [ConversationFilesystemEntry]
        if let cwd, !cwd.isEmpty {
            let slugDir = root.appendingPathComponent(
                Self.sessionSlug(forCwd: cwd, homeDirectory: filesystem.homeDirectory),
                isDirectory: true
            )
            entries = filesystem.listDirectoryByMtime(slugDir, max: maxCandidates)
        } else {
            entries = filesystem.listSessionsRecursivelyByMtime(
                root,
                extensionFilter: "jsonl",
                max: maxCandidates
            )
        }
        return entries.compactMap { entry in
            // `listDirectoryByMtime` returns every entry in the slug dir
            // (including the `<ts>_<uuid>/` log subdirs), so filter by suffix.
            guard entry.fileName.hasSuffix(".jsonl") else { return nil }
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
